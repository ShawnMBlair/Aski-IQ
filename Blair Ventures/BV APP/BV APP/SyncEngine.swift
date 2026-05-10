// SyncEngine.swift
// AskiCommand – Sync Engine
// Session 3: Added Supabase Realtime for live clock-in updates

import Foundation
import Combine
import Supabase

@MainActor
final class SyncEngine: ObservableObject {

    /// ISO 8601 parser shared across pull paths. Tries fractional-seconds
    /// first, then plain internet-date for sample-data and similar fields
    /// that may have been stamped without fractional precision.
    static func isoIn(_ s: String) -> Date? {
        struct F {
            static let withFrac: ISO8601DateFormatter = {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return f
            }()
            static let plain: ISO8601DateFormatter = {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime]
                return f
            }()
        }
        return F.withFrac.date(from: s) ?? F.plain.date(from: s)
    }

    static let shared = SyncEngine()

    /// Hard reset called as part of `AppStore.fullSignOutReset()`.
    /// Stops realtime subscriptions, clears the sync timestamps, and
    /// drops any in-flight sync error. Pairs with the tenant-isolation
    /// fix: when the next user signs in, `pullAll(for:role:)` starts
    /// from a clean slate with no stale lastSyncAt that would skip
    /// pull paths gated on staleness windows.
    func reset() {
        // Stop and nil out realtime tasks so the next user's sign-in
        // doesn't inherit channels keyed to the previous tenant.
        stopRealtime()
        realtimeTask?.cancel();     realtimeTask = nil
        realtimePullTask?.cancel(); realtimePullTask = nil
        crmRealtimeTask?.cancel();  crmRealtimeTask = nil

        isSyncing       = false
        lastSyncAt      = nil
        syncError       = nil
        onlineUserCount = 0
    }

    @Published var isSyncing = false
    @Published var lastSyncAt: Date? = nil
    @Published var syncError: String? = nil
    @Published var onlineUserCount: Int = 0

    let store = AppStore.shared
    private var realtimeTask: Task<Void, Never>? = nil
    private var realtimePullTask: Task<Void, Never>? = nil
    var crmRealtimeTask: Task<Void, Never>? = nil

    /// Injectable data client used by migrated push/pull functions.
    /// Production constructs SyncEngine via `init()` which uses
    /// LiveSyncClient(supabase) — byte-identical to pre-Phase-5
    /// behavior. Tests construct via `init(client:)` with a fake.
    /// Functions still using the direct `supabase.from(...)` chain
    /// migrate one at a time; both paths can coexist during the
    /// migration without behavior drift.
    let client: AskiSyncClient

    private init() {
        self.client = LiveSyncClient()
    }

    /// Test-only initializer. Marked internal so the BV APP Tests
    /// target can construct an isolated SyncEngine with a fake client,
    /// without exposing a public seam to the rest of the app.
    init(client: AskiSyncClient) {
        self.client = client
    }

    // MARK: - Pull on Launch

    func pullAll(for userID: UUID, role: UserRole) async {
        isSyncing = true
        syncError = nil
        defer { isSyncing = false }

        if role.isFieldRole || role == .client {
            await pullAssignedProjects(userID: userID)
        } else {
            await pullAllProjects()
        }

        await pullEmployees()
        // Phase 12 follow-up: cache tenant profiles so the
        // QuoteApprovalNotifier can route approval emails to the
        // actual managers / executives instead of just a shared
        // inbox. Cheap query — small table, single tenant, RLS
        // already filters to `company_id = get_my_company_id()`.
        await pullCompanyProfiles()
        await pullCrews()
        await pullScheduleEntries()
        await pullScheduleRecommendations()
        await pullTimesheets(userID: userID, role: role)
        await pullFormTemplates()
        await pullFormSubmissions(userID: userID, role: role)
        await pullIncidents(role: role)
        await pullCertificates()
        await pullClients(role: role)
        await pullDJRs(userID: userID, role: role)
        await pullEquipment()
        await pullChangeOrders(role: role)
        await pullRFIs(role: role)
        await pullProjectBudgets(role: role)
        await pullSubcontractors(role: role)
        await pullSubContracts(role: role)
        await pullInvoices(role: role)
        await pullProcurement(role: role)
        await pullEstimates(role: role)
        await pullQuotes(role: role)
        // 2026-05 fix: pullQuoteApprovals was only fired when the
        // user opened the dedicated approvals screen, so the
        // unified Approval Queue couldn't see pending quote
        // approvals on a fresh launch. Wired into the main pull
        // cycle so the cache stays warm.
        await pullQuoteApprovals()
        await pullMaterialSales()
        await pullProductServices()
        await pullClientPricings()
        // Contracts module — parent contracts first, then their child
        // clauses + milestones so foreign-key resolution always finds
        // a parent on the client side.
        await pullContracts()
        await pullContractClauses()
        await pullContractMilestones()
        await pullComplianceDocuments()
        await pullLienWaivers()

        // Cost codes — company-wide, visible to everyone
        await pullCostCodes()

        // Workflow automation — rules + audit log. Hydrate before
        // `runWorkflowEngine()` below so the engine evaluates the
        // server's rules, not whatever was on local disk.
        await pullWorkflowRules()
        await pullWorkflowLog()

        // 2026-04 re-audit fix #5: three collections that historically
        // pushed but never pulled. Operators now see audit trails,
        // exception logs, and import history written by other
        // devices on the same tenant.
        await pullAuditSnapshots()
        await pullExceptionLogs()
        await pullImportBatches()

        // Seed master list if this company has no codes yet
        await MainActor.run { store.seedCostCodesIfNeeded() }

        // CRM — visible to all non-client, non-field roles
        if role.canViewCRM {
            await pullCRMContacts()
            await pullCRMOpportunities()
            await pullCRMTasks(role: role)
            await pullCRMActivities()
            await pullCRMChecklists()
        }

        lastSyncAt = Date()
        // Phase 2 stabilization: signal that the first full pull is
        // done so create flows that depend on a populated local store
        // (MR / PO today, other modules to follow) can unlock. Set on
        // every successful pullAll, not just the first one — if the
        // user signed out and back in, the flag may have been reset.
        await MainActor.run { store.hasCompletedFirstSync = true }
        store.saveToDiskImmediately()

        // Run compliance sweep — fires cert/equipment alerts
        NotificationManager.shared.runComplianceSweep()

        // Run workflow automation engine
        store.runWorkflowEngine()

        // Start listening for real-time timesheet changes
        startRealtimeTimesheets()

        // Start listening for real-time CRM opportunity changes
        if store.currentUserRole.canViewCRM {
            startRealtimeCRM()
        }

        // 2026-04 re-audit fix #8: workflow rules realtime channel.
        // A manager toggling a rule on iPad now reflects on the
        // office iPhone within seconds instead of waiting up to
        // 15 min for the next BG pull.
        startRealtimeWorkflow()
    }

    // MARK: - Realtime — Live Timesheet Updates
    // Foreman and office see clock-ins the moment they happen

    func startRealtimeTimesheets() {
        guard let companyID = store.currentCompanyID else { return }
        realtimeTask?.cancel()
        // 2026-04 re-audit fix #4: outer reconnect loop. Pre-fix the
        // inner `for await` exits silently on disconnect and never
        // reconnects until the user backgrounds + foregrounds the app
        // (which retriggers `pullAll`). Now we wrap subscription +
        // listen in a retry loop with exponential backoff.
        realtimeTask = Task { [weak self] in
            await self?.realtimeRetryLoop(label: "timesheets") { [weak self] in
                guard let self else { return }
                let channel = await supabase.realtimeV2
                    .channel("timesheet_changes_\(companyID)")
                let changes = await channel.postgresChange(
                    AnyAction.self,
                    schema: "public",
                    table: SupabaseTable.timesheetEntries,
                    filter: "company_id=eq.\(companyID)"
                )
                await channel.subscribe()

                for await _ in changes {
                    self.realtimePullTask?.cancel()
                    self.realtimePullTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        guard !Task.isCancelled, let self,
                              let user = self.store.currentUser else { return }
                        await self.pullTimesheets(userID: user.id,
                                                  role: self.store.currentUserRole)
                    }
                }
                // Stream ended → caller decides whether to reconnect.
            }
        }
    }

    /// 2026-04 re-audit fix #4: shared reconnect helper for any
    /// realtime channel. Each iteration calls `start()`, which is
    /// expected to subscribe + run a `for await` listen. When that
    /// returns (i.e. the stream ended for any reason), we sleep with
    /// exponential backoff and try again. Cancellation propagates;
    /// `stopRealtime()` cancels the outer Task and the loop exits.
    ///
    /// Backoff: 2s, 4s, 8s, 16s, 32s, 60s (capped). Resets to 2s on
    /// every successful long-lived stream (any iteration that runs
    /// for >30s before returning).
    func realtimeRetryLoop(
        label: String,
        start: @escaping () async -> Void
    ) async {
        var backoffSeconds: UInt64 = 2
        let maxBackoffSeconds: UInt64 = 60
        let resetThresholdSeconds: TimeInterval = 30

        while !Task.isCancelled {
            let started = Date()
            await start()
            if Task.isCancelled { return }

            // If the listen body ran for long enough that the user
            // got value out of it, reset the backoff window so the
            // next disconnect doesn't start at 60s.
            let lifetime = Date().timeIntervalSince(started)
            if lifetime > resetThresholdSeconds {
                backoffSeconds = 2
            }

            // Don't bother retrying while the device is offline —
            // NetworkMonitor will trigger a fresh pullAll on
            // reconnect, and pullAll re-starts realtime channels.
            if AppStore.shared.isOfflineMode {
                print("⚠️ realtime[\(label)] offline; pausing reconnect")
                return
            }

            print("⚠️ realtime[\(label)] disconnected; retrying in \(backoffSeconds)s")
            try? await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)
            backoffSeconds = min(backoffSeconds * 2, maxBackoffSeconds)
        }
    }

    func stopRealtime() {
        realtimePullTask?.cancel()
        realtimePullTask = nil
        realtimeTask?.cancel()
        realtimeTask = nil
        crmRealtimeTask?.cancel()
        crmRealtimeTask = nil
    }

    // MARK: - Push Pending
    //
    // 2026-05 FIX: serialize concurrent push cycles. Pre-fix, every
    // upsertX() helper kicks `Task { await SyncEngine.shared.pushPending() }`
    // — a fire-and-forget cycle. When the user creates a project from
    // a quote (a flow that triggers multiple upserts in quick succession:
    // quote → opportunity → project → estimate update for backlinks),
    // 2-4 push cycles run in parallel. Each cycle internally awaits its
    // children in order, but cycles INTERLEAVE — Cycle A pushes the quote,
    // Cycle B pushes the project, etc. The race produces FK violations
    // (child references parent before parent lands) and RLS rejections
    // (quote_terms tries to write before the parent quote is on the
    // server). The next sync usually recovers, but the user sees the
    // failure toast and may lose nested entities pushed out-of-band.
    //
    // Fix: a single in-flight gate. If a push is already running,
    // queue exactly one follow-up cycle so any work that arrived
    // mid-flight is guaranteed to be picked up. Coalesces N concurrent
    // requests into at most 2 sequential cycles (current + follow-up),
    // which is sufficient because each cycle pushes everything pending.

    /// True while a push cycle is running. Guards entry into pushPending.
    private var isPushing: Bool = false
    /// True when at least one push request arrived while another was
    /// running. The runner reschedules itself once the current cycle
    /// completes. Set under the same actor isolation as `isPushing`.
    private var pendingFollowUp: Bool = false

    func pushPending() async {
        // Coalesce concurrent calls. Only the first request actually
        // executes; subsequent ones flip pendingFollowUp and return,
        // letting the running cycle decide whether to re-run after.
        if isPushing {
            pendingFollowUp = true
            return
        }
        isPushing = true
        defer {
            isPushing = false
            // Drain any follow-up that arrived during this cycle.
            // One re-run is enough — each cycle pushes everything
            // currently pending.
            if pendingFollowUp {
                pendingFollowUp = false
                Task { await pushPending() }
            }
        }
        await pushPendingInternal()
    }

    private func pushPendingInternal() async {
        // 2026-05 FIX: dependency-aware push order. Pre-fix order
        // produced FK + RLS errors when child entities (estimates,
        // quotes, project_budgets, audit_snapshots) pushed before
        // their parents (CRM opportunities, projects).
        //
        // The new order goes parent → child:
        //   1. Foundation: clients, employees, crews (referenced by many)
        //   2. CRM root: contacts → opportunities (referenced by quotes,
        //      estimates, projects)
        //   3. Project layer: projects (references opportunities)
        //   4. Sales layer: estimates (references project + opportunity)
        //      → quotes (references estimate + project + opportunity)
        //   5. Sales nested: estimate_terms, quote_terms
        //      (RLS requires parent estimate/quote to exist server-side)
        //   6. Material sales (separate sales path)
        //   7. Project sub-entities: change orders, RFIs, project_budgets,
        //      subcontracts, invoices, procurement
        //   8. Schedule layer: schedule_entries → audit log → recommendations
        //   9. Field/safety: timesheets, exceptions, incidents, certs, DJRs
        //  10. Operational: equipment, contracts, compliance
        //  11. Reports: form templates, form submissions, audit snapshots,
        //      workflow rules + log

        // 1. Foundation
        await pushPendingClients()
        await pushPendingEmployees()
        await pushPendingCrews()

        // 2. CRM root — MUST push before quotes/estimates/projects.
        // CRM role gate inverted: any user able to push downstream
        // entities (estimates, projects) needs opportunities to exist
        // for FK to resolve. The opportunity rows themselves are
        // tenant-scoped via RLS so a non-CRM user can't read them
        // back, but they CAN write the FK target — server enforces
        // ownership separately.
        await pushPendingCRMContacts()
        await pushPendingCRMOpportunities()

        // 3. Project layer
        await pushPendingProjects()

        // 4. Sales layer — order matters: estimate_id is a FK on quotes,
        // and estimates push first so quotes can reference them.
        // converted_quote_id (the back-link from estimate → quote) is
        // typically NULL on first push and updated on a follow-up cycle
        // after the quote lands; the serialization gate above ensures
        // the follow-up cycle runs after this one completes.
        //
        // material_sales also belongs here (not in step 6 like it used
        // to) — it has an optional FK to quotes (`quote_id`), AND its
        // child material_sale_terms RLS policy requires the parent
        // material_sale to already exist server-side. The 2026-05-09
        // Phase 4 audit caught a re-ordering bug where
        // pushPendingMaterialSaleTerms ran BEFORE
        // pushPendingMaterialSales, causing all material-sale-terms
        // pushes to fail RLS even though the policy itself was correct.
        // Fixed by moving material_sales push up next to quotes.
        await pushPendingEstimates()
        await pushPendingQuotes()
        await pushPendingMaterialSales()

        // 5. Sales nested — terms RLS requires parent quote / estimate /
        // material_sale to exist server-side. Push AFTER step 4.
        await pushPendingEstimateTerms()
        await pushPendingQuoteTerms()
        await pushPendingMaterialSaleTerms()

        // 7. Project sub-entities
        await pushPendingChangeOrders()
        await pushPendingRFIs()
        await pushPendingProjectBudgets()
        await pushPendingSubcontractors()
        await pushPendingSubContracts()
        await pushPendingInvoices()
        await pushPendingProcurement()

        // 8. Schedule layer — projects must exist; recommendations
        // and audit log push after their target schedule entries.
        await pushPendingScheduleEntries()
        await pushPendingScheduleAudits()
        await pushPendingScheduleRecommendations()

        // 9. Field / safety / compliance evidence
        await pushPendingTimesheets()
        await pushPendingExceptionLogs()
        await pushPendingIncidents()
        await pushPendingCertificates()
        await pushPendingDJRs()

        // 10. Operational
        await pushPendingEquipment()
        await pushPendingContracts()
        await pushPendingContractClauses()
        await pushPendingContractMilestones()
        await pushPendingComplianceDocuments()
        await pushPendingLienWaivers()

        // 11. Reports / library / settings — these have light FK deps
        // so they can run last without cascading failures.
        await pushPendingFormTemplates()
        await pushPendingFormSubmissions()
        await pushPendingAuditSnapshots()
        // Product/service library + per-client pricing overrides.
        // Products first (clientPricings has a soft FK to product_services.id).
        await pushPendingProductServices()
        await pushPendingClientPricings()
        // Workflow automation — rules + log.
        await pushPendingWorkflowRules()
        await pushPendingWorkflowLog()
        // Cost-code toggles (audit-driven fix).
        await pushPendingCompanyCostCodes()

        // CRM tail — tasks / activities / checklists reference
        // contacts and opportunities which are already pushed at step 2.
        if store.currentUserRole.canEditCRM {
            await pushPendingCRMTasks()
            await pushPendingCRMActivities()
            await pushPendingCRMChecklists()
        }
    }

    // MARK: - Pull Helpers

    private func pullAllProjects() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct ProjectRow: Codable {
                let id: String
                let name: String
                let clientName: String
                let status: String
                let siteAddress: String?
                let notes: String?
                let contractValue: Double?
                let estimatedBudget: Double?
                let companyId: String?
                // Slice 2 Entity-First: roll-up to CRM opportunity.
                let opportunityId: String?
                // Phase 1 follow-up: project ↔ crew linkage now persisted.
                // Optional so legacy rows (before the migration) decode as
                // nil and hydrate to []. Postgrest serializes uuid[] as
                // a JSON array of strings — decode into [String]? and map
                // through UUID(uuidString:) so a bad value is dropped, not
                // crashed on.
                let assignedCrewIds: [String]?
                /// Phase RA-1: same pattern for direct-worker linkage.
                let assignedWorkerIds: [String]?
                /// SR-1 follow-up: labor pre-plan crew preference.
                /// Inherited from Quote on convertQuoteToProject.
                let preferredCrewId: String?
                /// SR-1.4: structured labor requirements payload.
                /// JSONB — decoded as LaborRequirement directly.
                /// Optional on legacy rows (default '{}' on server).
                let laborPlan: LaborRequirement?
                // Sample-data tracking
                let isSampleData: Bool?
                let sampleDataBatchId: String?
                let sampleDataSeedVersion: String?
                let sampleDataCreatedAt: String?
                let sampleDataCreatedBy: String?
                enum CodingKeys: String, CodingKey {
                    case id, name, notes, status
                    case clientName      = "client_name"
                    case siteAddress     = "site_address"
                    case contractValue   = "contract_value"
                    case estimatedBudget = "estimated_budget"
                    case companyId       = "company_id"
                    case opportunityId   = "opportunity_id"
                    case assignedCrewIds = "assigned_crew_ids"
                    case assignedWorkerIds = "assigned_worker_ids"
                    case preferredCrewId = "preferred_crew_id"
                    case laborPlan = "labor_plan"
                    case isSampleData          = "is_sample_data"
                    case sampleDataBatchId     = "sample_data_batch_id"
                    case sampleDataSeedVersion = "sample_data_seed_version"
                    case sampleDataCreatedAt   = "sample_data_created_at"
                    case sampleDataCreatedBy   = "sample_data_created_by"
                }
            }
            let rows: [ProjectRow] = try await client.select(
                ProjectRow.self,
                from: SupabaseTable.projects,
                filters: [
                    .eq("company_id", companyID.uuidString),
                    .eq("is_deleted", false)
                ],
                orderBy: "name",
                ascending: true
            )

            store.projects = rows.map { row in
                var p = Project(name: row.name, clientName: row.clientName)
                p.id              = UUID(uuidString: row.id) ?? UUID()
                // Carry the tenant scope back into the local model so it
                // round-trips on the next push without us re-deriving it.
                p.companyID       = row.companyId.flatMap(UUID.init(uuidString:))
                p.status          = ProjectStatus(rawValue: row.status) ?? .active
                p.siteAddress     = row.siteAddress
                p.notes           = row.notes
                p.contractValue   = row.contractValue.map { Decimal($0) }
                p.estimatedBudget = row.estimatedBudget.map { Decimal($0) }
                p.opportunityID   = row.opportunityId.flatMap(UUID.init(uuidString:))
                // Phase 1 follow-up: hydrate assigned crews. Drop unparseable
                // strings rather than crash; an empty result is fine.
                p.assignedCrewIDs = (row.assignedCrewIds ?? []).compactMap { UUID(uuidString: $0) }
                // Phase RA-1: same pattern for direct-worker assignments.
                p.assignedWorkerIDs = (row.assignedWorkerIds ?? []).compactMap { UUID(uuidString: $0) }
                // SR-1 follow-up: hydrate the labor pre-plan signal.
                p.preferredCrewID = row.preferredCrewId.flatMap { UUID(uuidString: $0) }
                // SR-1.4: structured labor requirements. Defaults to
                // empty plan (no constraint) on legacy rows.
                p.laborPlan = row.laborPlan ?? LaborRequirement()
                p.syncStatus      = .synced
                // Sample-data flags survive round-trip so the in-memory
                // purge after Clear can find them.
                p.isSampleData          = row.isSampleData ?? false
                p.sampleDataBatchID     = row.sampleDataBatchId.flatMap(UUID.init(uuidString:))
                p.sampleDataSeedVersion = row.sampleDataSeedVersion
                p.sampleDataCreatedAt   = row.sampleDataCreatedAt.flatMap(SyncEngine.isoIn)
                p.sampleDataCreatedBy   = row.sampleDataCreatedBy.flatMap(UUID.init(uuidString:))
                return p
            }
        } catch {
            // 2026-05 fix: also log to console so a decoding failure
            // doesn't silently empty the Projects tab. Pre-fix, when
            // a new column added a Codable type that the auto-
            // synthesized decoder couldn't handle, the throw was
            // swallowed and `store.projects` stayed empty without
            // any visible signal.
            print("⚠️ pullAllProjects failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "pullAllProjects"])
            syncError = "Projects: \(error.localizedDescription)"
        }
    }

    private func pullAssignedProjects(userID: UUID) async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct AssignmentRow: Codable {
                let projectId: UUID
                enum CodingKeys: String, CodingKey {
                    case projectId = "project_id"
                }
            }
            let assignments: [AssignmentRow] = try await client.select(
                AssignmentRow.self,
                from: SupabaseTable.projectAssignments,
                columns: "project_id",
                filters: [.eq("user_id", userID.uuidString)],
                orderBy: nil,
                ascending: true,
                limit: nil
            )

            guard !assignments.isEmpty else {
                store.projects = []
                return
            }
            let ids = assignments.map { $0.projectId.uuidString }

            struct ProjectRow: Codable {
                let id: String
                let name: String
                let clientName: String
                let status: String
                let siteAddress: String?
                let notes: String?
                let contractValue: Double?
                let companyId: String?
                // Slice 2 Entity-First: roll-up to CRM opportunity.
                let opportunityId: String?
                // Phase 1 follow-up: project ↔ crew linkage.
                let assignedCrewIds: [String]?
                /// Phase RA-1: same pattern for direct-worker linkage.
                let assignedWorkerIds: [String]?
                /// SR-1 follow-up: labor pre-plan crew preference.
                /// Inherited from Quote on convertQuoteToProject.
                let preferredCrewId: String?
                /// SR-1.4: structured labor requirements payload.
                /// JSONB — decoded as LaborRequirement directly.
                /// Optional on legacy rows (default '{}' on server).
                let laborPlan: LaborRequirement?
                // Sample-data tracking
                let isSampleData: Bool?
                let sampleDataBatchId: String?
                let sampleDataSeedVersion: String?
                let sampleDataCreatedAt: String?
                let sampleDataCreatedBy: String?
                enum CodingKeys: String, CodingKey {
                    case id, name, notes, status
                    case clientName    = "client_name"
                    case siteAddress   = "site_address"
                    case contractValue = "contract_value"
                    case companyId     = "company_id"
                    case opportunityId = "opportunity_id"
                    case assignedCrewIds = "assigned_crew_ids"
                    case assignedWorkerIds = "assigned_worker_ids"
                    case preferredCrewId = "preferred_crew_id"
                    case laborPlan = "labor_plan"
                    case isSampleData          = "is_sample_data"
                    case sampleDataBatchId     = "sample_data_batch_id"
                    case sampleDataSeedVersion = "sample_data_seed_version"
                    case sampleDataCreatedAt   = "sample_data_created_at"
                    case sampleDataCreatedBy   = "sample_data_created_by"
                }
            }
            let rows: [ProjectRow] = try await client.select(
                ProjectRow.self,
                from: SupabaseTable.projects,
                filters: [
                    .eq("company_id", companyID.uuidString),
                    .in_("id", ids)
                ]
            )

            store.projects = rows.map { row in
                var p = Project(name: row.name, clientName: row.clientName)
                p.id            = UUID(uuidString: row.id) ?? UUID()
                // Carry the tenant scope back into the local model so it
                // round-trips on the next push without re-deriving it.
                p.companyID     = row.companyId.flatMap(UUID.init(uuidString:))
                p.status        = ProjectStatus(rawValue: row.status) ?? .active
                p.siteAddress   = row.siteAddress
                p.notes         = row.notes
                p.contractValue = row.contractValue.map { Decimal($0) }
                p.opportunityID = row.opportunityId.flatMap(UUID.init(uuidString:))
                // Phase 1 follow-up: hydrate assigned crews.
                p.assignedCrewIDs = (row.assignedCrewIds ?? []).compactMap { UUID(uuidString: $0) }
                // Phase RA-1: same pattern for direct-worker assignments.
                p.assignedWorkerIDs = (row.assignedWorkerIds ?? []).compactMap { UUID(uuidString: $0) }
                // SR-1 follow-up: hydrate the labor pre-plan signal.
                p.preferredCrewID = row.preferredCrewId.flatMap { UUID(uuidString: $0) }
                // SR-1.4: structured labor requirements. Defaults to
                // empty plan (no constraint) on legacy rows.
                p.laborPlan = row.laborPlan ?? LaborRequirement()
                p.syncStatus    = .synced
                p.isSampleData          = row.isSampleData ?? false
                p.sampleDataBatchID     = row.sampleDataBatchId.flatMap(UUID.init(uuidString:))
                p.sampleDataSeedVersion = row.sampleDataSeedVersion
                p.sampleDataCreatedAt   = row.sampleDataCreatedAt.flatMap(SyncEngine.isoIn)
                p.sampleDataCreatedBy   = row.sampleDataCreatedBy.flatMap(UUID.init(uuidString:))
                return p
            }
        } catch {
            print("⚠️ pullAssignedProjects failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "pullAssignedProjects"])
            syncError = "Assigned projects: \(error.localizedDescription)"
        }
    }

    private func pullEmployees() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct EmployeeRow: Codable {
                let id: String
                let firstName: String
                let lastName: String
                let email: String?
                let phone: String?
                let role: String
                let trade: String?
                let isActive: Bool
                let companyId: String?
                // Sample-data tracking
                let isSampleData: Bool?
                let sampleDataBatchId: String?
                let sampleDataSeedVersion: String?
                let sampleDataCreatedAt: String?
                let sampleDataCreatedBy: String?
                enum CodingKeys: String, CodingKey {
                    case id, email, phone, role, trade
                    case firstName = "first_name"
                    case lastName  = "last_name"
                    case isActive  = "is_active"
                    case companyId = "company_id"
                    case isSampleData          = "is_sample_data"
                    case sampleDataBatchId     = "sample_data_batch_id"
                    case sampleDataSeedVersion = "sample_data_seed_version"
                    case sampleDataCreatedAt   = "sample_data_created_at"
                    case sampleDataCreatedBy   = "sample_data_created_by"
                }
            }
            let rows: [EmployeeRow] = try await client.select(
                EmployeeRow.self,
                from: SupabaseTable.employees,
                filters: [
                    .eq("company_id", companyID.uuidString),
                    .eq("is_active", true)
                ]
            )

            store.employees = rows.map { row in
                var e = Employee(firstName: row.firstName, lastName: row.lastName)
                e.id         = UUID(uuidString: row.id) ?? UUID()
                // Round-trip tenant scope so the next push doesn't have to
                // re-derive it from `currentCompanyID`.
                e.companyID  = row.companyId.flatMap(UUID.init(uuidString:))
                e.email      = row.email
                e.phone      = row.phone
                e.role       = UserRole(rawValue: row.role) ?? .fieldWorker
                e.trade      = row.trade
                e.isActive   = row.isActive
                e.syncStatus = .synced
                e.isSampleData          = row.isSampleData ?? false
                e.sampleDataBatchID     = row.sampleDataBatchId.flatMap(UUID.init(uuidString:))
                e.sampleDataSeedVersion = row.sampleDataSeedVersion
                e.sampleDataCreatedAt   = row.sampleDataCreatedAt.flatMap(SyncEngine.isoIn)
                e.sampleDataCreatedBy   = row.sampleDataCreatedBy.flatMap(UUID.init(uuidString:))
                return e
            }
        } catch {
            print("⚠️ pullEmployees failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "pullEmployees"])
            syncError = "Employees: \(error.localizedDescription)"
        }
    }

    private func pullCrews() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct CrewRow: Codable {
                let id: String
                let name: String
                let foremanId: String?
                let isActive: Bool
                let notes: String?
                let companyId: String?
                enum CodingKeys: String, CodingKey {
                    case id, name, notes
                    case foremanId = "foreman_id"
                    case isActive  = "is_active"
                    case companyId = "company_id"
                }
            }
            let rows: [CrewRow] = try await client.select(
                CrewRow.self,
                from: SupabaseTable.crews,
                filters: [
                    .eq("company_id", companyID.uuidString),
                    .eq("is_active", true)
                ]
            )

            store.crews = rows.map { row in
                var c = Crew(name: row.name)
                c.id         = UUID(uuidString: row.id) ?? UUID()
                // Carry tenant scope back so the next push round-trips it.
                c.companyID  = row.companyId.flatMap(UUID.init(uuidString:))
                c.foremanID  = row.foremanId.flatMap { UUID(uuidString: $0) }
                c.isActive   = row.isActive
                c.notes      = row.notes
                c.syncStatus = .synced
                return c
            }
        } catch {
            syncError = "Crews: \(error.localizedDescription)"
        }
    }

    func pullTimesheets(userID: UUID, role: UserRole) async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct TimesheetRow: Codable {
                let id: String
                let projectId: String
                let employeeId: String
                let workDate: String
                let regularHours: Double
                let overtimeHours: Double
                let costCode: String?
                let approvalStatus: String
                let companyId: String?
                enum CodingKeys: String, CodingKey {
                    case id
                    case projectId      = "project_id"
                    case employeeId     = "employee_id"
                    case workDate       = "work_date"
                    case regularHours   = "regular_hours"
                    case overtimeHours  = "overtime_hours"
                    case costCode       = "cost_code"
                    case approvalStatus = "approval_status"
                    case companyId      = "company_id"
                }
            }

            var filters: [SyncFilter] = [.eq("company_id", companyID.uuidString)]
            if role == .fieldWorker {
                filters.append(.eq("employee_id", userID.uuidString))
            }

            let rows: [TimesheetRow] = try await client.select(
                TimesheetRow.self,
                from: SupabaseTable.timesheetEntries,
                filters: filters,
                orderBy: "work_date",
                ascending: false,
                limit: 500
            )

            store.timesheetEntries = rows.map { row in
                let parsedDate = _syncDateFormatter.date(from: row.workDate) ?? Date()
                var e = TimesheetEntry(
                    projectID:  UUID(uuidString: row.projectId) ?? UUID(),
                    employeeID: UUID(uuidString: row.employeeId) ?? UUID(),
                    date: parsedDate
                )
                e.id             = UUID(uuidString: row.id) ?? UUID()
                e.companyID      = row.companyId.flatMap(UUID.init(uuidString:))
                e.regularHours   = fromDouble(row.regularHours)
                e.overtimeHours  = fromDouble(row.overtimeHours)
                e.costCode       = row.costCode
                e.approvalStatus = ApprovalStatus(rawValue: row.approvalStatus) ?? .draft
                e.syncStatus     = .synced
                return e
            }
        } catch {
            syncError = "Timesheets: \(error.localizedDescription)"
        }
    }

    private func pullFormTemplates() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct TemplateRow: Codable {
                let id: String
                let name: String
                let category: String?
                let templateDescription: String?
                let requiresSignature: Bool
                let isActive: Bool
                let version: Int?
                let fieldsJson: String?
                let lastModifiedBy: String?
                let companyId: String?
                enum CodingKeys: String, CodingKey {
                    case id, name, category, version
                    case templateDescription = "description"
                    case requiresSignature   = "requires_signature"
                    case isActive            = "is_active"
                    case fieldsJson          = "fields_json"
                    case lastModifiedBy      = "last_modified_by"
                    case companyId           = "company_id"
                }
            }
            let rows: [TemplateRow] = try await client.select(
                TemplateRow.self,
                from: SupabaseTable.formTemplates,
                filters: [
                    .eq("company_id", companyID.uuidString),
                    .eq("is_active", true)
                ]
            )

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            // Merge: keep local-only / pending / failed records, overwrite synced ones.
            // Including .failed prevents data loss when push errors strand records.
            var merged = store.formTemplates.filter {
                $0.syncStatus == .local || $0.syncStatus == .pending || $0.syncStatus == .failed
            }
            for row in rows {
                var t = FormTemplate(name: row.name)
                t.id                = UUID(uuidString: row.id) ?? UUID()
                t.companyID         = row.companyId.flatMap(UUID.init(uuidString:))
                t.category          = row.category
                t.formDescription   = row.templateDescription
                t.requiresSignature = row.requiresSignature
                t.isActive          = row.isActive
                t.version           = row.version ?? 1
                t.lastModifiedBy    = row.lastModifiedBy ?? ""
                if let json = row.fieldsJson,
                   let data = json.data(using: .utf8),
                   let fields = try? decoder.decode([FormField].self, from: data) {
                    t.fields = fields
                }
                t.syncStatus = .synced
                // Replace any local version of this record
                merged.removeAll { $0.id == t.id }
                merged.append(t)
            }
            store.formTemplates = merged
        } catch {
            syncError = "Form templates: \(error.localizedDescription)"
        }
    }

    private func pullFormSubmissions(userID: UUID, role: UserRole) async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct SubmissionRow: Codable {
                let id: String
                let templateId: String
                let templateVersion: Int?
                let submittedBy: String
                let submittedAt: String?
                let projectId: String?
                let isSigned: Bool
                let signedAt: String?
                let signedBy: String?
                let isDraft: Bool?
                let linkType: String?
                let linkedName: String?
                let linkedAddress: String?
                let responsesJson: String?
                let auditHash: String?
                let lastModifiedBy: String?
                let companyId: String?
                enum CodingKeys: String, CodingKey {
                    case id
                    case templateId      = "template_id"
                    case templateVersion = "template_version"
                    case submittedBy     = "submitted_by"
                    case submittedAt     = "submitted_at"
                    case projectId       = "project_id"
                    case isSigned        = "is_signed"
                    case signedAt        = "signed_at"
                    case signedBy        = "signed_by"
                    case isDraft         = "is_draft"
                    case linkType        = "link_type"
                    case linkedName      = "linked_name"
                    case linkedAddress   = "linked_address"
                    case responsesJson   = "responses_json"
                    case auditHash       = "audit_hash"
                    case lastModifiedBy  = "last_modified_by"
                    case companyId       = "company_id"
                }
            }

            var filters: [SyncFilter] = [.eq("company_id", companyID.uuidString)]
            // Field workers only see their own submissions — filter by user UUID, not name
            if role == .fieldWorker {
                filters.append(.eq("user_id", userID.uuidString))
            }

            let rows: [SubmissionRow] = try await client.select(
                SubmissionRow.self,
                from: SupabaseTable.formSubmissions,
                filters: filters,
                orderBy: "created_at",
                ascending: false,
                limit: 500
            )

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            // Merge: keep local drafts / pending / failed, overwrite synced ones.
            // Including .failed prevents data loss when a push error strands records.
            var merged = store.formSubmissions.filter {
                $0.syncStatus == .local || $0.syncStatus == .pending || $0.syncStatus == .failed
            }
            for row in rows {
                var s = FormSubmission(
                    templateID:  UUID(uuidString: row.templateId) ?? UUID(),
                    submittedBy: row.submittedBy
                )
                s.id              = UUID(uuidString: row.id) ?? UUID()
                s.companyID       = row.companyId.flatMap(UUID.init(uuidString:))
                s.templateVersion = row.templateVersion ?? 1
                s.projectID       = row.projectId.flatMap { UUID(uuidString: $0) }
                s.submittedAt     = row.submittedAt.flatMap { iso.date(from: $0) }
                s.isSigned        = row.isSigned
                s.signedAt        = row.signedAt.flatMap { iso.date(from: $0) }
                s.signedBy        = row.signedBy
                s.isDraft         = row.isDraft ?? false
                s.linkType        = FormLinkType(rawValue: row.linkType ?? "none") ?? .none
                s.linkedName      = row.linkedName
                s.linkedAddress   = row.linkedAddress
                if let json = row.responsesJson,
                   let data = json.data(using: .utf8),
                   let responses = try? decoder.decode([FormFieldResponse].self, from: data) {
                    s.responses = responses
                }
                s.auditHash      = row.auditHash
                s.lastModifiedBy = row.lastModifiedBy ?? ""
                s.syncStatus     = .synced
                merged.removeAll { $0.id == s.id }
                merged.append(s)
            }
            store.formSubmissions = merged
            // Download photos/signatures from Storage for any responses that have keys but no local data
            Task { await downloadMissingFormPhotos() }
        } catch {
            syncError = "Form submissions: \(error.localizedDescription)"
        }
    }

    /// Downloads photos and signatures from Supabase Storage for synced form responses
    /// that have storage keys but no local binary data (i.e. pulled from another device).
    private func downloadMissingFormPhotos() async {
        for si in store.formSubmissions.indices {
            for ri in store.formSubmissions[si].responses.indices {
                let resp = store.formSubmissions[si].responses[ri]

                // Photos
                if !resp.photoStorageKeys.isEmpty && resp.photoData.isEmpty {
                    var photos: [Data] = []
                    for key in resp.photoStorageKeys {
                        if let data = try? await supabase.storage
                            .from("form-photos")
                            .download(path: key) {
                            photos.append(data)
                        }
                    }
                    if !photos.isEmpty {
                        store.formSubmissions[si].responses[ri].photoData = photos
                    }
                }

                // Signature
                if let sigKey = resp.signatureStorageKey, resp.signatureData == nil {
                    if let data = try? await supabase.storage
                        .from("form-photos")
                        .download(path: sigKey) {
                        store.formSubmissions[si].responses[ri].signatureData = data
                    }
                }
            }
        }
    }

    // MARK: - Push Helpers

    // MARK: - Push Form Templates

    private func pushPendingFormTemplates() async {
        let pending = store.formTemplates.filter { $0.syncStatus == .pending }
        for template in pending {
            guard let companyID = store.currentCompanyID else { continue }
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let fieldsJson = (try? encoder.encode(template.fields))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                let groupsJson = (try? encoder.encode(template.groups))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

                struct Row: Codable {
                    let id, name, companyId: String
                    let category, templateDescription: String?
                    let requiresSignature, isActive: Bool
                    let version: Int
                    let fieldsJson: String
                    let lastModifiedBy: String?
                    let isDeleted: Bool
                    let deletedAt: String?
                    let deletedBy: String?
                    enum CodingKeys: String, CodingKey {
                        case id, name, category, version
                        case companyId           = "company_id"
                        case templateDescription = "description"
                        case requiresSignature   = "requires_signature"
                        case isActive            = "is_active"
                        case fieldsJson          = "fields_json"
                        case lastModifiedBy      = "last_modified_by"
                        case isDeleted           = "is_deleted"
                        case deletedAt           = "deleted_at"
                        case deletedBy           = "deleted_by"
                    }
                }
                let _isoFmt: ISO8601DateFormatter = {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    return f
                }()
                let row = Row(
                    id:                  template.id.uuidString,
                    name:                template.name,
                    companyId:           companyID.uuidString,
                    category:            template.category,
                    templateDescription: template.formDescription,
                    requiresSignature:   template.requiresSignature,
                    isActive:            template.isActive,
                    version:             template.version,
                    fieldsJson:          fieldsJson,
                    lastModifiedBy:      template.lastModifiedBy.isEmpty ? nil : template.lastModifiedBy,
                    isDeleted:           template.isDeleted,
                    deletedAt:           template.deletedAt.map { _isoFmt.string(from: $0) },
                    deletedBy:           template.deletedBy
                )
                try await supabase
                    .from(SupabaseTable.formTemplates)
                    .upsert(row)
                    .execute()
                if let i = store.formTemplates.firstIndex(where: { $0.id == template.id }) {
                    store.formTemplates[i].syncStatus = .synced
                }
                store.formTemplates.removeAll { $0.isDeleted && $0.syncStatus == .synced }
            } catch {
                if let i = store.formTemplates.firstIndex(where: { $0.id == template.id }) {
                    store.formTemplates[i].syncStatus = .failed
                }
            }
        }
    }

    private func pushPendingTimesheets() async {
        let pending = store.timesheetEntries.filter { $0.syncStatus == .pending }
        for entry in pending {
            guard let companyID = store.currentCompanyID else { continue }
            do {
                struct Row: Codable {
                    let id, projectId, employeeId, workDate, companyId: String
                    let regularHours, overtimeHours: Double
                    let costCode, approvalStatus, lastModifiedBy: String?
                    let isDeleted: Bool
                    let deletedAt: String?
                    let deletedBy: String?
                    enum CodingKeys: String, CodingKey {
                        case id
                        case companyId      = "company_id"
                        case projectId      = "project_id"
                        case employeeId     = "employee_id"
                        case workDate       = "work_date"
                        case regularHours   = "regular_hours"
                        case overtimeHours  = "overtime_hours"
                        case costCode       = "cost_code"
                        case approvalStatus = "approval_status"
                        case lastModifiedBy = "last_modified_by"
                        case isDeleted      = "is_deleted"
                        case deletedAt      = "deleted_at"
                        case deletedBy      = "deleted_by"
                    }
                }
                let _isoFmt: ISO8601DateFormatter = {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    return f
                }()
                let row = Row(
                    id:             entry.id.uuidString,
                    projectId:      entry.projectID.uuidString,
                    employeeId:     entry.employeeID.uuidString,
                    workDate:       entry.date.iso8601Date,
                    companyId:      companyID.uuidString,
                    regularHours:   NSDecimalNumber(decimal: entry.regularHours).doubleValue,
                    overtimeHours:  NSDecimalNumber(decimal: entry.overtimeHours).doubleValue,
                    costCode:       entry.costCode,
                    approvalStatus: entry.approvalStatus.rawValue,
                    lastModifiedBy: entry.lastModifiedBy,
                    isDeleted:      entry.isDeleted,
                    deletedAt:      entry.deletedAt.map { _isoFmt.string(from: $0) },
                    deletedBy:      entry.deletedBy
                )
                try await supabase
                    .from(SupabaseTable.timesheetEntries)
                    .upsert(row)
                    .execute()
                if let i = store.timesheetEntries.firstIndex(where: { $0.id == entry.id }) {
                    store.timesheetEntries[i].syncStatus = .synced
                }
                store.timesheetEntries.removeAll { $0.isDeleted && $0.syncStatus == .synced }
            } catch {
                if let i = store.timesheetEntries.firstIndex(where: { $0.id == entry.id }) {
                    store.timesheetEntries[i].syncStatus = .failed
                }
            }
        }
    }

    private func pushPendingFormSubmissions() async {
        let pending = store.formSubmissions.filter { $0.syncStatus == .pending }
        for submission in pending {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

                // Upload photos and signatures to Supabase Storage; store keys in responses.
                // Raw binary is stripped from the JSON payload — only Storage keys travel via DB.
                var syncableResponses = submission.responses
                let submissionFolder = submission.id.uuidString
                for i in syncableResponses.indices {
                    let fieldID = syncableResponses[i].fieldID.uuidString

                    // Photos — upload each Data blob, record the Storage path
                    if !syncableResponses[i].photoData.isEmpty {
                        var keys: [String] = syncableResponses[i].photoStorageKeys
                        for (idx, photoData) in syncableResponses[i].photoData.enumerated() {
                            // Only upload if we don't already have a key for this index
                            if idx >= keys.count {
                                let path = "\(submissionFolder)/\(fieldID)_\(idx).jpg"
                                if (try? await supabase.storage
                                        .from("form-photos")
                                        .upload(path, data: photoData,
                                                options: FileOptions(contentType: "image/jpeg", upsert: true))) != nil {
                                    keys.append(path)
                                }
                            }
                        }
                        syncableResponses[i].photoStorageKeys = keys
                        // Persist keys back to the in-memory store so we don't re-upload on next push
                        if let si = store.formSubmissions.firstIndex(where: { $0.id == submission.id }),
                           let ri = store.formSubmissions[si].responses.firstIndex(where: { $0.id == syncableResponses[i].id }) {
                            store.formSubmissions[si].responses[ri].photoStorageKeys = keys
                        }
                    }
                    syncableResponses[i].photoData = []   // strip raw data from DB payload

                    // Signature — upload Data blob, record the Storage path
                    if let sigData = syncableResponses[i].signatureData,
                       syncableResponses[i].signatureStorageKey == nil {
                        let path = "\(submissionFolder)/sig_\(fieldID).png"
                        if (try? await supabase.storage
                                .from("form-photos")
                                .upload(path, data: sigData,
                                        options: FileOptions(contentType: "image/png", upsert: true))) != nil {
                            syncableResponses[i].signatureStorageKey = path
                            if let si = store.formSubmissions.firstIndex(where: { $0.id == submission.id }),
                               let ri = store.formSubmissions[si].responses.firstIndex(where: { $0.id == syncableResponses[i].id }) {
                                store.formSubmissions[si].responses[ri].signatureStorageKey = path
                            }
                        }
                    }
                    syncableResponses[i].signatureData = nil  // strip raw data from DB payload
                }
                let responsesJson = (try? encoder.encode(syncableResponses))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

                let linkedCoordJson: String? = submission.linkedCoordinate
                    .flatMap { try? encoder.encode($0) }
                    .flatMap { String(data: $0, encoding: .utf8) }

                guard let companyID = store.currentCompanyID else { continue }

                struct Row: Codable {
                    let id, templateId, submittedBy: String
                    let companyId: String
                    let templateVersion: Int
                    let projectId: String?
                    let submittedAt, signedAt, signedBy: String?
                    let isSigned, isDraft: Bool
                    let linkType: String
                    let linkedName, linkedAddress, responsesJson: String?
                    let auditHash: String?
                    let lastModifiedBy: String?
                    let isDeleted: Bool
                    let deletedAt: String?
                    let deletedBy: String?
                    enum CodingKeys: String, CodingKey {
                        case id
                        case companyId       = "company_id"
                        case templateId      = "template_id"
                        case templateVersion = "template_version"
                        case projectId       = "project_id"
                        case submittedBy     = "submitted_by"
                        case submittedAt     = "submitted_at"
                        case isSigned        = "is_signed"
                        case signedAt        = "signed_at"
                        case signedBy        = "signed_by"
                        case isDraft         = "is_draft"
                        case linkType        = "link_type"
                        case linkedName      = "linked_name"
                        case linkedAddress   = "linked_address"
                        case responsesJson   = "responses_json"
                        case auditHash       = "audit_hash"
                        case lastModifiedBy  = "last_modified_by"
                        case isDeleted       = "is_deleted"
                        case deletedAt       = "deleted_at"
                        case deletedBy       = "deleted_by"
                    }
                }
                let row = Row(
                    id:              submission.id.uuidString,
                    templateId:      submission.templateID.uuidString,
                    submittedBy:     submission.submittedBy,
                    companyId:       companyID.uuidString,
                    templateVersion: submission.templateVersion,
                    projectId:       submission.projectID?.uuidString,
                    submittedAt:     submission.submittedAt.map { iso.string(from: $0) },
                    signedAt:        submission.signedAt.map { iso.string(from: $0) },
                    signedBy:        submission.signedBy,
                    isSigned:        submission.isSigned,
                    isDraft:         submission.isDraft,
                    linkType:        submission.linkType.rawValue,
                    linkedName:      submission.linkedName,
                    linkedAddress:   submission.linkedAddress,
                    responsesJson:   responsesJson,
                    auditHash:       submission.auditHash,
                    lastModifiedBy:  submission.lastModifiedBy.isEmpty ? nil : submission.lastModifiedBy,
                    isDeleted:       submission.isDeleted,
                    deletedAt:       submission.deletedAt.map { iso.string(from: $0) },
                    deletedBy:       submission.deletedBy
                )
                try await supabase
                    .from(SupabaseTable.formSubmissions)
                    .upsert(row)
                    .execute()
                if let i = store.formSubmissions.firstIndex(where: { $0.id == submission.id }) {
                    store.formSubmissions[i].syncStatus = .synced
                }
                store.formSubmissions.removeAll { $0.isDeleted && $0.syncStatus == .synced }
            } catch {
                if let i = store.formSubmissions.firstIndex(where: { $0.id == submission.id }) {
                    store.formSubmissions[i].syncStatus = .failed
                }
            }
        }
    }

    /// Loads audit snapshots from Supabase into the local store. Used by the
    /// AuditLogView so admins can see history beyond the current session.
    /// Capped at the most recent 500 entries — pagination would need a real
    /// cursor-based viewer; for now 500 covers ~1 month at typical activity.
    func pullAuditSnapshots(limit: Int = 500) async {
        guard let companyID = store.currentCompanyID else { return }
        struct Row: Codable {
            let id:            String
            let created_at:    String
            let record_type:   String
            let record_id:     String
            let event_type:    String
            let performed_by:  String
            let snapshot_json: String
            let company_id:    String?
        }
        do {
            let rows: [Row] = try await client.select(
                Row.self,
                from: SupabaseTable.auditSnapshots,
                filters: [.eq("company_id", companyID.uuidString)],
                orderBy: "created_at",
                ascending: false,
                limit: limit
            )
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoFallback = ISO8601DateFormatter()
            let snapshots: [AuditSnapshot] = rows.compactMap { row in
                guard let id   = UUID(uuidString: row.id),
                      let eid  = UUID(uuidString: row.record_id) else { return nil }
                let date = iso.date(from: row.created_at)
                        ?? isoFallback.date(from: row.created_at)
                        ?? Date()
                return AuditSnapshot(
                    id:            id,
                    entityType:    row.record_type,
                    entityID:      eid,
                    eventType:     row.event_type,
                    snapshotData:  row.snapshot_json.data(using: .utf8) ?? Data(),
                    createdAt:     date,
                    createdBy:     row.performed_by,
                    companyID:     UUID(uuidString: row.company_id ?? ""),
                    syncStatus:    .synced
                )
            }
            // Merge: keep any local .pending records not yet synced; replace the
            // rest with what came back from server.
            let pending = store.auditSnapshots.filter { $0.syncStatus == .pending }
            store.auditSnapshots = pending + snapshots
        } catch {
            print("[SyncEngine] pullAuditSnapshots failed: \(error)")
        }
    }

    /// Pushes locally-created audit snapshots up to Supabase.
    /// Public so AppStore.createAuditSnapshot can fire-and-forget on each event.
    func pushPendingAuditSnapshots() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.auditSnapshots.filter { $0.syncStatus == .pending }
        guard !pending.isEmpty else { return }
        struct Row: Codable {
            let id: String
            let createdAt: String
            let recordType: String
            let recordId: String
            let eventType: String
            let performedBy: String
            let snapshotJson: String
            let companyId: String
            enum CodingKeys: String, CodingKey {
                case id
                case createdAt    = "created_at"
                case recordType   = "record_type"
                case recordId     = "record_id"
                case eventType    = "event_type"
                case performedBy  = "performed_by"
                case snapshotJson = "snapshot_json"
                case companyId    = "company_id"
            }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for snapshot in pending {
            let jsonString = String(data: snapshot.snapshotData, encoding: .utf8) ?? "{}"
            let row = Row(
                id:            snapshot.id.uuidString,
                createdAt:     iso.string(from: snapshot.createdAt),
                recordType:    snapshot.entityType,
                recordId:      snapshot.entityID.uuidString,
                eventType:     snapshot.eventType,
                performedBy:   snapshot.createdBy,
                snapshotJson:  jsonString,
                companyId:     companyID.uuidString
            )
            do {
                try await supabase
                    .from(SupabaseTable.auditSnapshots)
                    .upsert(row)
                    .execute()
                if let i = store.auditSnapshots.firstIndex(where: { $0.id == snapshot.id }) {
                    store.auditSnapshots[i].syncStatus = .synced
                }
            } catch {
                if let i = store.auditSnapshots.firstIndex(where: { $0.id == snapshot.id }) {
                    store.auditSnapshots[i].syncStatus = .failed
                }
            }
        }
    }

    /// 2026-04 re-audit fix #5a: pulls audit snapshots written by other
    /// devices / Edge Functions into the local cache so admins on
    /// device B can see device A's audit trail. Capped at 500 most-
    /// recent rows per pull — anything older lives only on the server.
    func pullAuditSnapshots() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id: String
                let created_at: String
                let record_type: String
                let record_id: String
                let event_type: String
                let performed_by: String
                let snapshot_json: String
                let company_id: String
            }
            let rows: [Row] = try await client.select(
                Row.self,
                from: SupabaseTable.auditSnapshots,
                filters: [.eq("company_id", companyID.uuidString)],
                orderBy: "created_at",
                ascending: false,
                limit: 500
            )

            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()

            // Preserve any locally-pending snapshots so a flush-in-flight
            // doesn't get overwritten by the pull.
            let pendingIDs = Set(store.auditSnapshots
                .filter { $0.syncStatus == .pending || $0.syncStatus == .failed }
                .map { $0.id })
            var merged: [AuditSnapshot] = store.auditSnapshots.filter { pendingIDs.contains($0.id) }

            for row in rows {
                guard let id    = UUID(uuidString: row.id),
                      !pendingIDs.contains(id),
                      let recID = UUID(uuidString: row.record_id),
                      let cid   = UUID(uuidString: row.company_id) else { continue }
                let date  = iso.date(from: row.created_at)
                        ?? plain.date(from: row.created_at)
                        ?? Date()
                let data  = row.snapshot_json.data(using: .utf8) ?? Data()
                merged.append(AuditSnapshot(
                    id:           id,
                    entityType:   row.record_type,
                    entityID:     recID,
                    eventType:    row.event_type,
                    snapshotData: data,
                    createdAt:    date,
                    createdBy:    row.performed_by,
                    companyID:    cid,
                    syncStatus:   .synced
                ))
            }
            await MainActor.run {
                store.auditSnapshots = merged
                    .sorted { $0.createdAt > $1.createdAt }
            }
        } catch {
            print("⚠️ pullAuditSnapshots failed: \(error)")
        }
    }

    /// 2026-04 re-audit fix #5b: pulls exception logs written by
    /// other devices into the local cache. The iOS struct is leaner
    /// than the DB schema (timesheet/employee/project IDs all live
    /// only server-side) — we hydrate just the fields the iOS UI
    /// reads, leaving the richer fields for the server-side
    /// reporting view. Capped at 500.
    func pullExceptionLogs() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            // Phase 1 Step 2: pull the new company_id column. Fields are
            // snake_case to match the Postgres column names; CodingKeys
            // would mean an extra struct, snake_case decoding is fine
            // here because every other field is already snake_case.
            struct Row: Codable {
                let id: String
                let company_id: String?
                let exception_type: String
                let description: String
                let created_at: String
                let updated_at: String
                let timesheet_id: String?
                let last_modified_by: String?
                let is_deleted: Bool
            }
            let rows: [Row] = try await client.select(
                Row.self,
                from: SupabaseTable.exceptionLogs,
                columns: "id,company_id,exception_type,description,created_at,updated_at,timesheet_id,last_modified_by,is_deleted",
                filters: [
                    .eq("company_id", companyID.uuidString),
                    .eq("is_deleted", false)
                ],
                orderBy: "created_at",
                ascending: false,
                limit: 500
            )

            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()

            // Same merge-with-pending pattern as audit snapshots.
            let pendingIDs = Set(store.exceptionLogs
                .filter { $0.syncStatus == .pending || $0.syncStatus == .failed }
                .map { $0.id })
            var merged = store.exceptionLogs.filter { pendingIDs.contains($0.id) }

            for row in rows {
                guard let id = UUID(uuidString: row.id),
                      !pendingIDs.contains(id),
                      let type = ExceptionType(rawValue: row.exception_type) else { continue }

                // Phase 1 Step 2 — defense in depth.
                // RLS already filters by company_id server-side, so a
                // mismatch here is impossible under normal operation. If
                // it ever happens (cached query bypass, replication bug,
                // service-role key leaked into the anon client), we drop
                // the row AND surface it loudly. Quiet skipping would
                // cover up exactly the kind of regression we want to see.
                let rowCompanyID = row.company_id.flatMap { UUID(uuidString: $0) }
                if let rcid = rowCompanyID, rcid != companyID {
                    print("⛔ pullExceptionLogs cross-tenant row id=\(id) row.company=\(rcid) session.company=\(companyID) — dropping")
                    CrashReporter.capture(
                        message: "exception_logs cross-tenant row dropped",
                        level: .error,
                        context: [
                            "row_id":           id.uuidString,
                            "row_company_id":   rcid.uuidString,
                            "session_company":  companyID.uuidString
                        ]
                    )
                    continue
                }

                var log = ExceptionLog(
                    relatedEntryID: row.timesheet_id.flatMap { UUID(uuidString: $0) } ?? UUID(),
                    type:           type,
                    description:    row.description
                )
                log.id              = id
                log.companyID       = rowCompanyID ?? companyID
                log.createdAt       = iso.date(from: row.created_at) ?? plain.date(from: row.created_at) ?? Date()
                log.updatedAt       = iso.date(from: row.updated_at) ?? log.createdAt
                log.lastModifiedBy  = row.last_modified_by ?? ""
                log.lastModifiedAt  = log.updatedAt
                log.syncStatus      = .synced
                merged.append(log)
            }
            await MainActor.run {
                store.exceptionLogs = merged
                    .sorted { $0.createdAt > $1.createdAt }
            }
        } catch {
            print("⚠️ pullExceptionLogs failed: \(error)")
        }
    }

    /// 2026-04 re-audit fix #5c: hydrates import batch history so the
    /// Import History screen shows runs from other devices / web. Pre-
    /// fix the screen would always be empty until the user ran an
    /// import on this device.
    func pullImportBatches() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id: String
                let company_id: String
                let uploaded_by: String
                let file_name: String
                let record_type: String
                let status: String
                let template_version: String
                let total_rows: Int
                let created_count: Int
                let updated_count: Int
                let skipped_count: Int
                let error_count: Int
                let created_at: String
                let completed_at: String?
                let tab_summary: String?
            }
            let rows: [Row] = try await client.select(
                Row.self,
                from: SupabaseTable.importBatches,
                filters: [
                    .eq("company_id", companyID.uuidString),
                    .eq("is_deleted", false)
                ],
                orderBy: "created_at",
                ascending: false,
                limit: 200
            )

            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()

            var hydrated: [ImportBatch] = []
            for row in rows {
                guard let id    = UUID(uuidString: row.id),
                      let cid   = UUID(uuidString: row.company_id),
                      let uid   = UUID(uuidString: row.uploaded_by) else { continue }
                // iOS ImportBatch.recordType is a `String` carrying
                // an `ImportRecordType.rawValue`, not the enum itself,
                // so we just pass the raw string through.
                var b = ImportBatch(
                    id:              id,
                    companyID:       cid,
                    uploadedBy:      uid,
                    fileName:        row.file_name,
                    recordType:      row.record_type,
                    templateVersion: row.template_version
                )
                b.status       = ImportStatus(rawValue: row.status) ?? .draft
                b.totalRows    = row.total_rows
                b.created      = row.created_count
                b.updated      = row.updated_count
                b.skipped      = row.skipped_count
                b.errorCount   = row.error_count
                b.createdAt    = iso.date(from: row.created_at) ?? plain.date(from: row.created_at) ?? Date()
                b.completedAt  = row.completed_at.flatMap { iso.date(from: $0) ?? plain.date(from: $0) }
                hydrated.append(b)
            }
            await MainActor.run {
                store.importBatches = hydrated
            }
        } catch {
            print("⚠️ pullImportBatches failed: \(error)")
        }
    }

    private func pushPendingExceptionLogs() async {
        // Phase 1 Step 2: tenant chokepoint. We refuse to push if the
        // current session does not have a companyID set — the row would
        // be rejected by RLS anyway, but a hard bail here avoids the
        // round-trip and keeps the row in `.pending` so it will retry
        // once auth resolves.
        guard let companyID = store.currentCompanyID else {
            print("⛔ pushPendingExceptionLogs — no currentCompanyID, skipping cycle")
            return
        }

        let pending = store.exceptionLogs.filter { $0.syncStatus == .pending }
        for log in pending {
            do {
                struct Row: Codable {
                    let id: String
                    let companyID: String
                    let exceptionType: String
                    let description: String
                    enum CodingKeys: String, CodingKey {
                        case id, description
                        case companyID = "company_id"
                        case exceptionType = "exception_type"
                    }
                }
                // Send the row's stamped companyID if present, otherwise
                // fall back to the live session companyID. The trigger is
                // the final safety net, but explicit > implicit.
                let stamp = log.companyID ?? companyID
                let row = Row(
                    id:            log.id.uuidString,
                    companyID:     stamp.uuidString,
                    exceptionType: log.type.rawValue,
                    description:   log.description
                )
                try await supabase
                    .from(SupabaseTable.exceptionLogs)
                    .upsert(row)
                    .execute()
                if let i = store.exceptionLogs.firstIndex(where: { $0.id == log.id }) {
                    store.exceptionLogs[i].syncStatus = .synced
                    // Backfill the in-memory copy if it was created
                    // before the model carried companyID.
                    if store.exceptionLogs[i].companyID == nil {
                        store.exceptionLogs[i].companyID = stamp
                    }
                }
            } catch {
                if let i = store.exceptionLogs.firstIndex(where: { $0.id == log.id }) {
                    store.exceptionLogs[i].syncStatus = .failed
                }
            }
        }
    }

    private func pushPendingProjects() async {
        let pending = store.projects.filter { $0.syncStatus == .pending }
        for project in pending {
            guard let companyID = store.currentCompanyID else { continue }
            do {
                struct Row: Codable {
                    let id, name, clientName, status, companyId: String
                    let siteAddress, notes: String?
                    let contractValue, estimatedBudget: Double?
                    let opportunityId: String?     // Slice 2 Entity-First
                    // Phase 1 follow-up: project ↔ crew linkage.
                    // Always sent (not optional) so a project that had its
                    // last crew removed pushes back as []. Postgrest
                    // accepts a JSON array of UUID strings into uuid[].
                    let assignedCrewIds: [String]
                    /// Phase RA-1: same pattern for direct-worker linkage.
                    let assignedWorkerIds: [String]
                    /// SR-1 follow-up: labor pre-plan crew preference.
                    let preferredCrewId: String?
                    /// SR-1.4: full labor requirements payload.
                    /// Always sent — empty struct = "no plan".
                    let laborPlan: LaborRequirement
                    let lastModifiedBy: String
                    let isDeleted: Bool
                    let deletedAt: String?
                    let deletedBy: String?
                    // Sample-data tracking
                    let isSampleData: Bool
                    let sampleDataBatchId: String?
                    let sampleDataSeedVersion: String?
                    let sampleDataCreatedAt: String?
                    let sampleDataCreatedBy: String?
                    enum CodingKeys: String, CodingKey {
                        case id, name, notes, status
                        case companyId       = "company_id"
                        case clientName      = "client_name"
                        case siteAddress     = "site_address"
                        case contractValue   = "contract_value"
                        case estimatedBudget = "estimated_budget"
                        case opportunityId   = "opportunity_id"
                        case assignedCrewIds = "assigned_crew_ids"
                        case assignedWorkerIds = "assigned_worker_ids"
                        case preferredCrewId = "preferred_crew_id"
                        case laborPlan = "labor_plan"
                        case lastModifiedBy  = "last_modified_by"
                        case isDeleted       = "is_deleted"
                        case deletedAt       = "deleted_at"
                        case deletedBy       = "deleted_by"
                        case isSampleData          = "is_sample_data"
                        case sampleDataBatchId     = "sample_data_batch_id"
                        case sampleDataSeedVersion = "sample_data_seed_version"
                        case sampleDataCreatedAt   = "sample_data_created_at"
                        case sampleDataCreatedBy   = "sample_data_created_by"
                    }
                }
                let _isoFmt: ISO8601DateFormatter = {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    return f
                }()
                let row = Row(
                    id:              project.id.uuidString,
                    name:            project.name,
                    clientName:      project.clientName,
                    status:          project.status.rawValue,
                    companyId:       companyID.uuidString,
                    siteAddress:     project.siteAddress,
                    notes:           project.notes,
                    contractValue:   project.contractValue.map { NSDecimalNumber(decimal: $0).doubleValue },
                    estimatedBudget: project.estimatedBudget.map { NSDecimalNumber(decimal: $0).doubleValue },
                    opportunityId:   project.opportunityID?.uuidString,
                    // Phase 1 follow-up: send the assigned crew set so the
                    // server-derived backfill stays in sync with the iOS
                    // truth (manual edits + schedule-derived assignments).
                    assignedCrewIds: project.assignedCrewIDs.map { $0.uuidString },
                    // Phase RA-1: same pattern for worker assignments.
                    assignedWorkerIds: project.assignedWorkerIDs.map { $0.uuidString },
                    // SR-1 follow-up: labor pre-plan crew preference.
                    preferredCrewId: project.preferredCrewID?.uuidString,
                    // SR-1.4: full labor requirements payload.
                    laborPlan: project.laborPlan,
                    lastModifiedBy:  project.lastModifiedBy,
                    isDeleted:       project.isDeleted,
                    deletedAt:       project.deletedAt.map { _isoFmt.string(from: $0) },
                    deletedBy:       project.deletedBy,
                    isSampleData:          project.isSampleData,
                    sampleDataBatchId:     project.sampleDataBatchID?.uuidString,
                    sampleDataSeedVersion: project.sampleDataSeedVersion,
                    sampleDataCreatedAt:   project.sampleDataCreatedAt.map { _isoFmt.string(from: $0) },
                    sampleDataCreatedBy:   project.sampleDataCreatedBy?.uuidString
                )
                try await supabase
                    .from(SupabaseTable.projects)
                    .upsert(row)
                    .execute()
                if let i = store.projects.firstIndex(where: { $0.id == project.id }) {
                    store.projects[i].syncStatus = .synced
                }
                store.projects.removeAll { $0.isDeleted && $0.syncStatus == .synced }
            } catch {
                if let i = store.projects.firstIndex(where: { $0.id == project.id }) {
                    store.projects[i].syncStatus = .failed
                }
            }
        }
    }

    private func pushPendingEmployees() async {
        let pending = store.employees.filter { $0.syncStatus == .pending }
        for employee in pending {
            guard let companyID = store.currentCompanyID else { continue }
            do {
                struct Row: Codable {
                    let id, firstName, lastName, role, companyId: String
                    let email, phone, trade: String?
                    let isActive: Bool
                    let isDeleted: Bool
                    let deletedAt: String?
                    let deletedBy: String?
                    // Sample-data tracking
                    let isSampleData: Bool
                    let sampleDataBatchId: String?
                    let sampleDataSeedVersion: String?
                    let sampleDataCreatedAt: String?
                    let sampleDataCreatedBy: String?
                    enum CodingKeys: String, CodingKey {
                        case id, email, phone, role, trade
                        case companyId = "company_id"
                        case firstName = "first_name"
                        case lastName  = "last_name"
                        case isActive  = "is_active"
                        case isDeleted = "is_deleted"
                        case deletedAt = "deleted_at"
                        case deletedBy = "deleted_by"
                        case isSampleData          = "is_sample_data"
                        case sampleDataBatchId     = "sample_data_batch_id"
                        case sampleDataSeedVersion = "sample_data_seed_version"
                        case sampleDataCreatedAt   = "sample_data_created_at"
                        case sampleDataCreatedBy   = "sample_data_created_by"
                    }
                }
                let _isoFmt: ISO8601DateFormatter = {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    return f
                }()
                let row = Row(
                    id:        employee.id.uuidString,
                    firstName: employee.firstName,
                    lastName:  employee.lastName,
                    role:      employee.role.rawValue,
                    companyId: companyID.uuidString,
                    email:     employee.email,
                    phone:     employee.phone,
                    trade:     employee.trade,
                    isActive:  employee.isActive,
                    isDeleted: employee.isDeleted,
                    deletedAt: employee.deletedAt.map { _isoFmt.string(from: $0) },
                    deletedBy: employee.deletedBy,
                    isSampleData:          employee.isSampleData,
                    sampleDataBatchId:     employee.sampleDataBatchID?.uuidString,
                    sampleDataSeedVersion: employee.sampleDataSeedVersion,
                    sampleDataCreatedAt:   employee.sampleDataCreatedAt.map { _isoFmt.string(from: $0) },
                    sampleDataCreatedBy:   employee.sampleDataCreatedBy?.uuidString
                )
                try await supabase
                    .from(SupabaseTable.employees)
                    .upsert(row)
                    .execute()
                if let i = store.employees.firstIndex(where: { $0.id == employee.id }) {
                    store.employees[i].syncStatus = .synced
                }
                store.employees.removeAll { $0.isDeleted && $0.syncStatus == .synced }
            } catch {
                print("⚠️ pushPendingEmployees failed for \(employee.id): \(error)")
                CrashReporter.capture(error: error,
                                      context: ["operation":  "pushPendingEmployees",
                                                "employee_id": employee.id.uuidString])
                if let i = store.employees.firstIndex(where: { $0.id == employee.id }) {
                    store.employees[i].syncStatus = .failed
                }
            }
        }
    }

    private func pushPendingCrews() async {
        let pending = store.crews.filter { $0.syncStatus == .pending }
        for crew in pending {
            guard let companyID = store.currentCompanyID else { continue }
            do {
                struct Row: Codable {
                    let id, name, companyId: String
                    let foremanId, notes: String?
                    let isActive: Bool
                    let isDeleted: Bool
                    let deletedAt: String?
                    let deletedBy: String?
                    enum CodingKeys: String, CodingKey {
                        case id, name, notes
                        case companyId = "company_id"
                        case foremanId = "foreman_id"
                        case isActive  = "is_active"
                        case isDeleted = "is_deleted"
                        case deletedAt = "deleted_at"
                        case deletedBy = "deleted_by"
                    }
                }
                let _isoFmt: ISO8601DateFormatter = {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    return f
                }()
                let row = Row(
                    id:        crew.id.uuidString,
                    name:      crew.name,
                    companyId: companyID.uuidString,
                    foremanId: crew.foremanID?.uuidString,
                    notes:     crew.notes,
                    isActive:  crew.isActive,
                    isDeleted: crew.isDeleted,
                    deletedAt: crew.deletedAt.map { _isoFmt.string(from: $0) },
                    deletedBy: crew.deletedBy
                )
                try await supabase
                    .from(SupabaseTable.crews)
                    .upsert(row)
                    .execute()
                if let i = store.crews.firstIndex(where: { $0.id == crew.id }) {
                    store.crews[i].syncStatus = .synced
                }
                store.crews.removeAll { $0.isDeleted && $0.syncStatus == .synced }
            } catch {
                if let i = store.crews.firstIndex(where: { $0.id == crew.id }) {
                    store.crews[i].syncStatus = .failed
                }
            }
        }
    }

    // MARK: - Schedule Entries Pull

    private func pullScheduleEntries() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, project_id, date: String
                let crew_id, task_description, cost_code, notes: String?
                let is_deleted: Bool?
                let company_id: String?
                /// Phase 1 scheduling upgrade — JSONB array of free-text
                /// cert names. Optional on decode for legacy rows.
                let required_certifications: [String]?
                /// Phase RA-1 — flexible assignment model. All three are
                /// optional on decode so legacy rows pre-RA-1 (which won't
                /// have these columns hydrated) decode as defaults:
                /// fixedCrew + empty workers + nil foreman.
                let assignment_mode: String?
                let assigned_worker_ids: [String]?
                let foreman_id: String?
            }
            let rows: [Row] = try await client.select(
                Row.self,
                from: SupabaseTable.scheduleEntries,
                filters: [
                    .eq("company_id", companyID.uuidString),
                    .eq("is_deleted", false)
                ]
            )

            // Include .failed so push-rejected entries survive across pulls.
            var merged = store.scheduleEntries.filter {
                $0.syncStatus == .pending || $0.syncStatus == .local || $0.syncStatus == .failed
            }
            for row in rows {
                guard let uuid   = UUID(uuidString: row.id),
                      let projID = UUID(uuidString: row.project_id) else { continue }
                let dateFmt = DateFormatter()
                dateFmt.dateFormat = "yyyy-MM-dd"
                guard let date = dateFmt.date(from: row.date) else { continue }
                var entry = ScheduleEntry(projectID: projID, date: date)
                entry.id              = uuid
                entry.companyID       = row.company_id.flatMap(UUID.init(uuidString:))
                entry.crewID          = row.crew_id.flatMap { UUID(uuidString: $0) }
                entry.taskDescription = row.task_description
                entry.costCode        = row.cost_code
                entry.notes           = row.notes
                entry.requiredCertifications = row.required_certifications ?? []
                // Phase RA-1: flexible assignment hydration.
                // Defensive: unrecognized mode strings fall back to
                // fixedCrew so a server-side schema drift doesn't
                // crash the decoder.
                entry.assignmentMode  = row.assignment_mode
                    .flatMap { ScheduleAssignmentMode(rawValue: $0) }
                    ?? .fixedCrew
                entry.assignedWorkerIDs = (row.assigned_worker_ids ?? [])
                    .compactMap { UUID(uuidString: $0) }
                entry.foremanID       = row.foreman_id.flatMap { UUID(uuidString: $0) }
                entry.isDeleted       = row.is_deleted ?? false
                entry.syncStatus      = .synced
                merged.removeAll { $0.id == uuid }
                if !(entry.isDeleted) { merged.append(entry) }
            }
            store.scheduleEntries = merged
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    private func pushPendingScheduleEntries() async {
        let pending = store.scheduleEntries.filter { $0.syncStatus == .pending }
        for entry in pending {
            guard let companyID = store.currentCompanyID else { continue }
            do {
                let isoFmt: ISO8601DateFormatter = {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    return f
                }()
                struct Row: Codable {
                    let id, projectId, date, companyId: String
                    let crewId, notes: String?
                    /// Phase 1 scheduling upgrade — JSONB array of cert
                    /// names. Always sent (empty array when no req).
                    let requiredCertifications: [String]
                    /// Phase RA-1 — assignment model. Always sent so the
                    /// server-side CHECK constraint runs against the
                    /// truth. Default fixed_crew preserves legacy rows.
                    let assignmentMode: String
                    let assignedWorkerIds: [String]
                    let foremanId: String?
                    let isDeleted: Bool
                    let deletedAt: String?
                    let deletedBy: String?
                    enum CodingKeys: String, CodingKey {
                        case id, date, notes
                        case companyId             = "company_id"
                        case projectId             = "project_id"
                        case crewId                = "crew_id"
                        case requiredCertifications = "required_certifications"
                        case assignmentMode        = "assignment_mode"
                        case assignedWorkerIds     = "assigned_worker_ids"
                        case foremanId             = "foreman_id"
                        case isDeleted             = "is_deleted"
                        case deletedAt             = "deleted_at"
                        case deletedBy             = "deleted_by"
                    }
                }
                let row = Row(
                    id:                     entry.id.uuidString,
                    projectId:              entry.projectID.uuidString,
                    date:                   entry.date.iso8601Date,
                    companyId:              companyID.uuidString,
                    crewId:                 entry.crewID?.uuidString,
                    notes:                  entry.notes,
                    requiredCertifications: entry.requiredCertifications,
                    assignmentMode:         entry.assignmentMode.rawValue,
                    assignedWorkerIds:      entry.assignedWorkerIDs.map { $0.uuidString },
                    foremanId:              entry.foremanID?.uuidString,
                    isDeleted:              entry.isDeleted,
                    deletedAt:              entry.deletedAt.map { isoFmt.string(from: $0) },
                    deletedBy:              entry.deletedBy
                )
                try await supabase
                    .from(SupabaseTable.scheduleEntries)
                    .upsert(row)
                    .execute()
                if let i = store.scheduleEntries.firstIndex(where: { $0.id == entry.id }) {
                    store.scheduleEntries[i].syncStatus = .synced
                }
                store.scheduleEntries.removeAll { $0.isDeleted && $0.syncStatus == .synced }
            } catch {
                if let i = store.scheduleEntries.firstIndex(where: { $0.id == entry.id }) {
                    store.scheduleEntries[i].syncStatus = .failed
                }
            }
        }
    }

    // MARK: - Schedule Audit Log Push (append-only, push-only)
    //
    // The audit log is one-way from device to server. We never pull
    // history back — when an admin needs to inspect prior changes
    // they query the table directly (or a future Schedule History
    // view will issue a paged select). Once a row is successfully
    // pushed it is dropped from the local array; if the push fails
    // the row stays `.pending` and retries on the next sync cycle.
    private func pushPendingScheduleAudits() async {
        let pending = store.scheduleAuditEvents.filter { $0.syncStatus == .pending }
        guard !pending.isEmpty else { return }
        let isoFmt: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        for event in pending {
            do {
                struct Row: Codable {
                    let id: String
                    let companyId: String
                    let scheduleEntryId: String
                    let projectId: String?
                    let userId: String?
                    let userName: String?
                    let action: String
                    let oldCrewId: String?
                    let newCrewId: String?
                    let oldDate: String?
                    let newDate: String?
                    let conflictDetected: Bool
                    let conflictTypes: [String]
                    let overrideUsed: Bool
                    let notes: String?
                    let createdAt: String
                    enum CodingKeys: String, CodingKey {
                        case id, action, notes
                        case companyId         = "company_id"
                        case scheduleEntryId   = "schedule_entry_id"
                        case projectId         = "project_id"
                        case userId            = "user_id"
                        case userName          = "user_name"
                        case oldCrewId         = "old_crew_id"
                        case newCrewId         = "new_crew_id"
                        case oldDate           = "old_date"
                        case newDate           = "new_date"
                        case conflictDetected  = "conflict_detected"
                        case conflictTypes     = "conflict_types"
                        case overrideUsed      = "override_used"
                        case createdAt         = "created_at"
                    }
                }
                let row = Row(
                    id:               event.id.uuidString,
                    companyId:        event.companyID.uuidString,
                    scheduleEntryId:  event.scheduleEntryID.uuidString,
                    projectId:        event.projectID?.uuidString,
                    userId:           event.userID?.uuidString,
                    userName:         event.userName,
                    action:           event.action.rawValue,
                    oldCrewId:        event.oldCrewID?.uuidString,
                    newCrewId:        event.newCrewID?.uuidString,
                    oldDate:          event.oldDate.map { isoFmt.string(from: $0) },
                    newDate:          event.newDate.map { isoFmt.string(from: $0) },
                    conflictDetected: event.conflictDetected,
                    conflictTypes:    event.conflictTypes,
                    overrideUsed:     event.overrideUsed,
                    notes:            event.notes,
                    createdAt:        isoFmt.string(from: event.createdAt)
                )
                try await supabase
                    .from(SupabaseTable.scheduleAuditLog)
                    .insert(row)
                    .execute()
                // Drop on success — audit history lives on the server.
                store.scheduleAuditEvents.removeAll { $0.id == event.id }
            } catch {
                if let i = store.scheduleAuditEvents.firstIndex(where: { $0.id == event.id }) {
                    store.scheduleAuditEvents[i].syncStatus = .failed
                }
                print("⚠️ pushPendingScheduleAudits failed: \(error)")
            }
        }
    }

    // MARK: - Schedule Recommendations Sync (SR-1)
    //
    // Two-way sync. Recommendations need pull because approval may
    // happen on a different device than generation. Push covers
    // engine-generated and manager-edited recommendations.

    private func pullScheduleRecommendations() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id: String
                let company_id: String
                let source_type: String
                let source_id: String
                let project_id: String?
                let recommendation_type: String?
                let created_by_ai: Bool?
                let requested_by_user_id: String?
                let status: String
                let confidence_score: Double?
                let summary: String?
                let reasoning: String?
                /// JSONB fields decoded as raw Data — we re-decode the
                /// inner payload manually because postgrest returns
                /// jsonb as already-parsed JSON (handled by the
                /// Codable decoder's nested-decode path automatically
                /// when the type matches).
                let risks: [ScheduleRisk]?
                let alternatives: [ScheduleAlternative]?
                let proposed_entries: [ProposedScheduleEntry]?
                let approved_by: String?
                let approved_at: String?
                let rejected_by: String?
                let rejected_at: String?
                let rejection_reason: String?
                /// SR-β: reviewer notes left when sending the plan
                /// back for revision. Optional on legacy rows.
                let review_notes: String?
                /// SR-γ: high-risk override reason + approval mode.
                /// Both optional — only stamped when a manager/exec
                /// approves a high-risk plan.
                let override_reason: String?
                let approval_mode: String?
                let applied_entry_ids: [String]?
                let applied_at: String?
                let created_at: String?
                let updated_at: String?
            }

            let rows: [Row] = try await client.select(
                Row.self,
                from: SupabaseTable.scheduleRecommendations,
                filters: [.eq("company_id", companyID.uuidString)]
            )

            // Same merge strategy as schedule_entries: keep local
            // pending/local/failed records so in-flight edits aren't
            // clobbered by the pull.
            var merged = store.scheduleRecommendations.filter {
                $0.syncStatus == .pending || $0.syncStatus == .local || $0.syncStatus == .failed
            }
            let isoFmt: ISO8601DateFormatter = {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return f
            }()
            let isoFmtNoFractional: ISO8601DateFormatter = {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime]
                return f
            }()
            func parseDate(_ s: String?) -> Date? {
                guard let s else { return nil }
                return isoFmt.date(from: s) ?? isoFmtNoFractional.date(from: s)
            }
            for row in rows {
                guard let id = UUID(uuidString: row.id),
                      let cid = UUID(uuidString: row.company_id),
                      let sid = UUID(uuidString: row.source_id),
                      let sourceType = ScheduleRecommendationSourceType(rawValue: row.source_type),
                      let status = ScheduleRecommendationStatus(rawValue: row.status) else {
                    continue
                }
                if merged.contains(where: { $0.id == id }) { continue }

                var rec = ScheduleRecommendation(
                    companyID: cid,
                    sourceType: sourceType,
                    sourceID: sid
                )
                rec.id = id
                rec.projectID = row.project_id.flatMap(UUID.init(uuidString:))
                rec.recommendationType = row.recommendation_type ?? "project_kickoff_schedule"
                rec.createdByAI = row.created_by_ai ?? true
                rec.requestedByUserID = row.requested_by_user_id.flatMap(UUID.init(uuidString:))
                rec.status = status
                rec.confidenceScore = row.confidence_score ?? 0
                rec.summary = row.summary ?? ""
                rec.reasoning = row.reasoning ?? ""
                rec.risks = row.risks ?? []
                rec.alternatives = row.alternatives ?? []
                rec.proposedEntries = row.proposed_entries ?? []
                rec.approvedBy = row.approved_by.flatMap(UUID.init(uuidString:))
                rec.approvedAt = parseDate(row.approved_at)
                rec.rejectedBy = row.rejected_by.flatMap(UUID.init(uuidString:))
                rec.rejectedAt = parseDate(row.rejected_at)
                rec.rejectionReason = row.rejection_reason
                rec.reviewNotes = row.review_notes
                rec.overrideReason = row.override_reason
                rec.approvalMode = row.approval_mode.flatMap { ApprovalMode(rawValue: $0) }
                rec.appliedEntryIDs = (row.applied_entry_ids ?? []).compactMap(UUID.init(uuidString:))
                rec.appliedAt = parseDate(row.applied_at)
                rec.createdAt = parseDate(row.created_at) ?? Date()
                rec.updatedAt = parseDate(row.updated_at) ?? Date()
                rec.syncStatus = .synced
                merged.append(rec)
            }
            store.scheduleRecommendations = merged
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    private func pushPendingScheduleRecommendations() async {
        let pending = store.scheduleRecommendations.filter { $0.syncStatus == .pending }
        guard !pending.isEmpty else { return }
        let isoFmt: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        for rec in pending {
            do {
                struct Row: Codable {
                    let id: String
                    let companyId: String
                    let sourceType: String
                    let sourceId: String
                    let projectId: String?
                    let recommendationType: String
                    let createdByAi: Bool
                    let requestedByUserId: String?
                    let status: String
                    let confidenceScore: Double
                    let summary: String
                    let reasoning: String?
                    let risks: [ScheduleRisk]
                    let alternatives: [ScheduleAlternative]
                    let proposedEntries: [ProposedScheduleEntry]
                    let approvedBy: String?
                    let approvedAt: String?
                    let rejectedBy: String?
                    let rejectedAt: String?
                    let rejectionReason: String?
                    /// SR-β: review notes for send-back.
                    let reviewNotes: String?
                    /// SR-γ: high-risk override reason + approval mode.
                    let overrideReason: String?
                    let approvalMode: String?
                    let appliedEntryIds: [String]
                    let appliedAt: String?
                    let updatedAt: String
                    enum CodingKeys: String, CodingKey {
                        case id, status, summary, reasoning, risks, alternatives
                        case companyId           = "company_id"
                        case sourceType          = "source_type"
                        case sourceId            = "source_id"
                        case projectId           = "project_id"
                        case recommendationType  = "recommendation_type"
                        case createdByAi         = "created_by_ai"
                        case requestedByUserId   = "requested_by_user_id"
                        case confidenceScore     = "confidence_score"
                        case proposedEntries     = "proposed_entries"
                        case approvedBy          = "approved_by"
                        case approvedAt          = "approved_at"
                        case rejectedBy          = "rejected_by"
                        case rejectedAt          = "rejected_at"
                        case rejectionReason     = "rejection_reason"
                        case reviewNotes         = "review_notes"
                        case overrideReason      = "override_reason"
                        case approvalMode        = "approval_mode"
                        case appliedEntryIds     = "applied_entry_ids"
                        case appliedAt           = "applied_at"
                        case updatedAt           = "updated_at"
                    }
                }
                let row = Row(
                    id: rec.id.uuidString,
                    companyId: rec.companyID.uuidString,
                    sourceType: rec.sourceType.rawValue,
                    sourceId: rec.sourceID.uuidString,
                    projectId: rec.projectID?.uuidString,
                    recommendationType: rec.recommendationType,
                    createdByAi: rec.createdByAI,
                    requestedByUserId: rec.requestedByUserID?.uuidString,
                    status: rec.status.rawValue,
                    confidenceScore: rec.confidenceScore,
                    summary: rec.summary,
                    reasoning: rec.reasoning,
                    risks: rec.risks,
                    alternatives: rec.alternatives,
                    proposedEntries: rec.proposedEntries,
                    approvedBy: rec.approvedBy?.uuidString,
                    approvedAt: rec.approvedAt.map { isoFmt.string(from: $0) },
                    rejectedBy: rec.rejectedBy?.uuidString,
                    rejectedAt: rec.rejectedAt.map { isoFmt.string(from: $0) },
                    rejectionReason: rec.rejectionReason,
                    reviewNotes: rec.reviewNotes,
                    overrideReason: rec.overrideReason,
                    approvalMode: rec.approvalMode?.rawValue,
                    appliedEntryIds: rec.appliedEntryIDs.map { $0.uuidString },
                    appliedAt: rec.appliedAt.map { isoFmt.string(from: $0) },
                    updatedAt: isoFmt.string(from: rec.updatedAt)
                )
                try await supabase
                    .from(SupabaseTable.scheduleRecommendations)
                    .upsert(row)
                    .execute()
                if let i = store.scheduleRecommendations.firstIndex(where: { $0.id == rec.id }) {
                    store.scheduleRecommendations[i].syncStatus = .synced
                }
            } catch {
                if let i = store.scheduleRecommendations.firstIndex(where: { $0.id == rec.id }) {
                    store.scheduleRecommendations[i].syncStatus = .failed
                }
                print("⚠️ pushPendingScheduleRecommendations failed: \(error)")
            }
        }
    }

    // MARK: - Incidents Sync

    private func pullIncidents(role: UserRole) async {
        guard !role.isExternal, let companyID = store.currentCompanyID else { return }
        do {
            struct IncidentRow: Codable {
                let id: String; let title: String; let incident_type: String
                let severity: String; let status: String; let project_id: String?
                let reported_by_name: String; let incident_date: String
                let description: String?; let created_at: String
                let company_id: String?
            }
            let rows: [IncidentRow] = try await client.select(
                IncidentRow.self,
                from: SupabaseTable.incidents,
                filters: [
                    .eq("company_id", companyID.uuidString),
                    .eq("is_deleted", false)
                ]
            )

            // ── Replace strategy ────────────────────────────────────────────
            // Build the authoritative list from Supabase, preserving any local
            // records that are still pending a push (so in-flight edits aren't lost).
            // Using replace (not merge) prevents phantom record accumulation:
            // previously, clearing in-memory data and re-pulling would re-add every
            // Supabase row on top of the freshly loaded sample data indefinitely.
            // Include .failed so a server-rejected incident isn't silently dropped.
            let pendingLocal = store.incidents.filter {
                $0.syncStatus == .pending || $0.syncStatus == .local || $0.syncStatus == .failed
            }

            var fresh: [Incident] = pendingLocal
            for row in rows {
                guard let uuid = UUID(uuidString: row.id) else { continue }
                // Don't overwrite a local record we're about to push
                if pendingLocal.contains(where: { $0.id == uuid }) { continue }
                var inc            = Incident(title: row.title)
                inc.id             = uuid
                inc.companyID      = row.company_id.flatMap(UUID.init(uuidString:))
                inc.reportedByName = row.reported_by_name
                inc.syncStatus     = .synced
                fresh.append(inc)
            }

            store.incidents = fresh
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    /// Deletes ALL incident records for the current company from Supabase, then
    /// clears the in-memory array. Call this from the Admin panel when phantom
    /// test/sample records need to be wiped from the server.
    func purgeAllIncidentsFromServer() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            try await supabase
                .from(SupabaseTable.incidents)
                .delete()
                .eq("company_id", value: companyID.uuidString)
                .execute()
            store.incidents = []
        } catch {
            print("purgeAllIncidentsFromServer error: \(error)")
        }
    }

    private func pushPendingIncidents() async {
        let pending = store.incidents.filter { $0.syncStatus == .pending || $0.syncStatus == .local }
        let _isoFmt: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        for inc in pending {
            guard let companyID = store.currentCompanyID else { continue }
            do {
                var payload: [String: AnyJSON] = [
                    "id":               .string(inc.id.uuidString),
                    "company_id":       .string(companyID.uuidString),
                    "title":            .string(inc.title),
                    "incident_type":    .string(inc.incidentType.rawValue),
                    "severity":         .string(inc.severity.rawValue),
                    "status":           .string(inc.status.rawValue),
                    "reported_by_name": .string(inc.reportedByName),
                    "incident_date":    .string(inc.incidentDate.iso8601Date),
                    "is_deleted":       .bool(inc.isDeleted),
                    "deleted_by":       inc.deletedBy.map { .string($0) } ?? .null
                ]
                if let deletedAt = inc.deletedAt {
                    payload["deleted_at"] = .string(_isoFmt.string(from: deletedAt))
                }
                try await client.upsert(payload, into: SupabaseTable.incidents)
                var updated = inc; updated.syncStatus = .synced
                store.upsertIncident(updated)
                store.incidents.removeAll { $0.isDeleted && $0.syncStatus == .synced }
            } catch {
                print("⚠️ \(#function) failed: \(error)")
                CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
            }
        }
    }

    // MARK: - Certificates Sync

    private func pullCertificates() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct CertRow: Codable {
                let id: String; let employee_id: String; let name: String
                let issuer: String?; let expiry_date: String?
                let company_id: String?
            }
            let rows: [CertRow] = try await client.select(
                CertRow.self,
                from: SupabaseTable.certificates,
                filters: [
                    .eq("company_id", companyID.uuidString),
                    .eq("is_deleted", false)
                ]
            )

            for row in rows {
                guard let uuid = UUID(uuidString: row.id),
                      let empID = UUID(uuidString: row.employee_id) else { continue }
                if store.certificates.contains(where: { $0.id == uuid && $0.syncStatus == .synced }) { continue }
                var cert = Certificate(employeeID: empID)
                cert.id          = uuid
                cert.companyID   = row.company_id.flatMap(UUID.init(uuidString:))
                cert.customName  = row.name
                cert.issuingBody = row.issuer
                cert.expiryDate  = row.expiry_date.flatMap { _syncDateFormatter.date(from: $0) }
                cert.syncStatus  = .synced
                store.upsertCertificate(cert)
            }
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    private func pushPendingCertificates() async {
        let pending = store.certificates.filter { $0.syncStatus == .pending || $0.syncStatus == .local }
        let _isoFmt: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        for cert in pending {
            guard let companyID = store.currentCompanyID else { continue }
            do {
                var payload: [String: AnyJSON] = [
                    "id":          .string(cert.id.uuidString),
                    "company_id":  .string(companyID.uuidString),
                    "employee_id": .string(cert.employeeID.uuidString),
                    "name":        .string(cert.displayName),
                    "issuer":      .string(cert.issuingBody ?? ""),
                    "is_deleted":  .bool(cert.isDeleted),
                    "deleted_by":  cert.deletedBy.map { .string($0) } ?? .null
                ]
                if let exp = cert.expiryDate {
                    payload["expiry_date"] = .string(exp.iso8601Date)
                }
                if let deletedAt = cert.deletedAt {
                    payload["deleted_at"] = .string(_isoFmt.string(from: deletedAt))
                }
                try await client.upsert(payload, into: SupabaseTable.certificates)
                var updated = cert; updated.syncStatus = .synced
                store.upsertCertificate(updated)
                // Purge soft-deleted certs: reload, filter, save
                let clean = store.certificates.filter { !($0.isDeleted && $0.syncStatus == .synced) }
                store.saveCertificatesPublic(clean)
            } catch {
                print("⚠️ \(#function) failed: \(error)")
                CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
            }
        }
    }

    // MARK: - Clients Sync

    private func pullClients(role: UserRole) async {
        guard !role.isFieldRole && !role.isExternal,
              let companyID = store.currentCompanyID else { return }
        do {
            struct ClientRow: Codable {
                let id: String; let name: String; let contact_name: String?
                let email: String?; let phone: String?
                let is_active: Bool?
                /// Stabilization fix: site list now persists server-side.
                /// Nullable in the row decoder so legacy rows (created
                /// before the column existed) decode to nil → empty list.
                let sites_json: String?
                // Sample-data tracking
                let is_sample_data: Bool?
                let sample_data_batch_id: String?
                let sample_data_seed_version: String?
                let sample_data_created_at: String?
                let sample_data_created_by: String?
            }
            let rows: [ClientRow] = try await client.select(
                ClientRow.self,
                from: SupabaseTable.clients,
                filters: [.eq("company_id", companyID.uuidString)]
            )

            for row in rows {
                guard let uuid = UUID(uuidString: row.id) else { continue }
                var client = store.clients.first(where: { $0.id == uuid }) ?? Client(name: row.name)
                client.id           = uuid
                client.name         = row.name
                client.contactName  = row.contact_name
                client.contactEmail = row.email
                client.contactPhone = row.phone
                client.isActive     = row.is_active ?? true
                // Stabilization fix: hydrate the sites array from the
                // server JSON. Pre-fix the in-memory sites array
                // survived a pull only by accident (the merge with the
                // existing local client preserved it); on cold launch
                // the local cache was empty and sites were lost.
                if let sitesJSON = row.sites_json,
                   let data     = sitesJSON.data(using: .utf8),
                   let sites    = try? JSONDecoder().decode([ClientSite].self, from: data) {
                    client.sites = sites
                }
                client.syncStatus   = .synced
                client.isSampleData          = row.is_sample_data ?? false
                client.sampleDataBatchID     = row.sample_data_batch_id.flatMap(UUID.init(uuidString:))
                client.sampleDataSeedVersion = row.sample_data_seed_version
                client.sampleDataCreatedAt   = row.sample_data_created_at.flatMap(SyncEngine.isoIn)
                client.sampleDataCreatedBy   = row.sample_data_created_by.flatMap(UUID.init(uuidString:))
                store.upsertClientSynced(client)
            }
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    // MARK: - Daily Job Reports Sync

    // Internal (was private) so the BV APP Tests target can drive
    // pullDJRs with a FakeSyncClient via @testable import.
    func pullDJRs(userID: UUID, role: UserRole) async {
        guard !role.isExternal, let companyID = store.currentCompanyID else { return }
        do {
            struct DJRRow: Codable {
                let id: String; let project_id: String
                let report_date: String; let prepared_by: String
                let work_summary: String?
                let report_number: String?
                let company_id: String?
            }
            // Phase 5 / Wave 2 (slice 4): migrated to AskiSyncClient seam.
            // The fake client returns whatever the test seeded into
            // cannedSelect[table]; the live client delegates to the same
            // supabase chain.
            let rows: [DJRRow] = try await client.select(
                DJRRow.self,
                from: SupabaseTable.dailyJobReports,
                filters: [
                    .eq("company_id", companyID.uuidString),
                    .eq("is_deleted", false)
                ]
            )

            for row in rows {
                guard let uuid = UUID(uuidString: row.id),
                      let projID = UUID(uuidString: row.project_id),
                      let date = _syncDateFormatter.date(from: row.report_date) else { continue }
                if store.allDailyJobReports().contains(where: { $0.id == uuid && $0.syncStatus == .synced }) { continue }
                var djr = DailyJobReport(projectID: projID,
                                         reportNumber: row.report_number ?? "",
                                         reportDate: date,
                                         submittedByName: row.prepared_by)
                djr.id            = uuid
                djr.companyID     = row.company_id.flatMap(UUID.init(uuidString:))
                djr.workPerformed = row.work_summary ?? ""
                djr.syncStatus    = .synced
                store.addDJR(djr)
            }
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    // Internal (was private) so the BV APP Tests target can drive
    // this push path with a FakeSyncClient via @testable import.
    // No production call sites changed — this is just access-level
    // relaxation for testability.
    func pushPendingDJRs() async {
        let pending = store.allDailyJobReports().filter { $0.syncStatus == .pending || $0.syncStatus == .local }
        let _isoFmt: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        for djr in pending {
            guard let companyID = store.currentCompanyID else { continue }
            do {
                var payload: [String: AnyJSON] = [
                    "id":            .string(djr.id.uuidString),
                    "company_id":    .string(companyID.uuidString),
                    "project_id":    .string(djr.projectID.uuidString),
                    "report_date":   .string(djr.reportDate.iso8601Date),
                    "prepared_by":   .string(djr.submittedByName),
                    "work_summary":  .string(djr.workPerformed),
                    "report_number": .string(djr.reportNumber),
                    "is_deleted":    .bool(djr.isDeleted),
                    "deleted_by":    djr.deletedBy.map { .string($0) } ?? .null
                ]
                if let deletedAt = djr.deletedAt {
                    payload["deleted_at"] = .string(_isoFmt.string(from: deletedAt))
                }
                // Phase 5 / Wave 2: migrated to AskiSyncClient. Live impl
                // delegates to the same supabase.from(...).upsert(...).execute()
                // chain, so prod behavior is unchanged. Tests can swap in a
                // FakeSyncClient and assert on the recorded payload.
                try await client.upsert(payload, into: SupabaseTable.dailyJobReports)
                var updated = djr; updated.syncStatus = .synced
                store.updateDJR(updated)
                await MainActor.run { store.clearSyncError(id: djr.id) }
            } catch {
                print("⚠️ \(#function) failed: \(error)")
                // Phase 2 Failed-Sync visibility: DJR push previously
                // only printed + sent to Sentry — failed rows weren't
                // marked .failed, so they were invisible in the Failed
                // Syncs UI. Now surface them properly.
                var failed = djr; failed.syncStatus = .failed
                store.updateDJR(failed)
                await MainActor.run { store.recordSyncError(id: djr.id, error: error) }
                CrashReporter.capture(error: error, context: [
                    "operation":     "\(#function)",
                    "djr_id":         djr.id.uuidString,
                    "djr_number":     djr.reportNumber
                ])
            }
        }
    }

    // MARK: - Equipment Sync

    private func pullEquipment() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct EquipRow: Codable {
                let id: String; let name: String; let equipment_type: String
                let status: String
                let serial_number: String?; let make: String?; let model: String?
                let company_id: String?
            }
            let rows: [EquipRow] = try await client.select(
                EquipRow.self,
                from: SupabaseTable.equipment,
                filters: [
                    .eq("company_id", companyID.uuidString),
                    .eq("is_deleted", false)
                ]
            )

            for row in rows {
                guard let uuid = UUID(uuidString: row.id),
                      let cat = EquipmentCategory(rawValue: row.equipment_type) else { continue }
                if store.equipment.contains(where: { $0.id == uuid && $0.syncStatus == .synced }) { continue }
                var item = Equipment(name: row.name, category: cat)
                item.id           = uuid
                item.companyID    = row.company_id.flatMap(UUID.init(uuidString:))
                item.status       = EquipmentStatus(rawValue: row.status) ?? .available
                item.serialNumber = row.serial_number ?? ""
                item.make         = row.make ?? ""
                item.model        = row.model ?? ""
                item.syncStatus   = .synced
                store.addEquipment(item)
            }
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    private func pushPendingEquipment() async {
        let pending = store.equipment.filter { $0.syncStatus == .pending || $0.syncStatus == .local }
        let _isoFmt: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        for item in pending {
            guard let companyID = store.currentCompanyID else { continue }
            do {
                var payload: [String: AnyJSON] = [
                    "id":             .string(item.id.uuidString),
                    "company_id":     .string(companyID.uuidString),
                    "name":           .string(item.name),
                    "equipment_type": .string(item.category.rawValue),
                    "status":         .string(item.status.rawValue),
                    "serial_number":  .string(item.serialNumber),
                    "make":           .string(item.make),
                    "model":          .string(item.model),
                    "is_deleted":     .bool(item.isDeleted),
                    "deleted_by":     item.deletedBy.map { .string($0) } ?? .null
                ]
                if let deletedAt = item.deletedAt {
                    payload["deleted_at"] = .string(_isoFmt.string(from: deletedAt))
                }
                try await client.upsert(payload, into: SupabaseTable.equipment)
                var updated = item; updated.syncStatus = .synced
                store.updateEquipment(updated)
                store.equipment.removeAll { $0.isDeleted && $0.syncStatus == .synced }
            } catch {
                print("⚠️ \(#function) failed: \(error)")
                CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
            }
        }
    }

    // MARK: - Cost Codes

    private func pullCostCodes() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            let rows: [CostCodeRow] = try await client.select(
                CostCodeRow.self,
                from: SupabaseTable.companyCostCodes,
                filters: [.eq("company_id", companyID.uuidString)]
            )
            let codes = rows.map { r -> CompanyCostCode in
                var c = CompanyCostCode(
                    companyID:   companyID,
                    code:        r.code,
                    description: r.description,
                    category:    CostCodeCategory(rawValue: r.category) ?? .labour,
                    isEnabled:   r.is_enabled,
                    isCustom:    r.is_custom,
                    sortOrder:   r.sort_order,
                    syncStatus:  .synced,
                    serviceTypes: (r.service_types ?? []).compactMap { ServiceType(rawValue: $0) }
                )
                c.id = r.id
                return c
            }
            await MainActor.run { store.companyCostCodes = codes }
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    func pushCostCode(_ code: CompanyCostCode) async {
        guard let companyID = code.companyID else { return }
        do {
            let payload: [String: AnyJSON] = [
                "id":          .string(code.id.uuidString),
                "company_id":  .string(companyID.uuidString),
                "code":        .string(code.code),
                "description": .string(code.description),
                "category":    .string(code.category.rawValue),
                "is_enabled":  .bool(code.isEnabled),
                "is_custom":   .bool(code.isCustom),
                "sort_order":  .double(Double(code.sortOrder)),
                // Slice C: persist service-type tags for auto-suggestion.
                // Server CHECK constraint enforces the vocabulary.
                "service_types": .array(code.serviceTypes.map { .string($0.rawValue) })
            ]
            try await client.upsert(payload, into: SupabaseTable.companyCostCodes)
            // Mark synced so the loop helper below stops retrying.
            if let i = store.companyCostCodes.firstIndex(where: { $0.id == code.id }) {
                store.companyCostCodes[i].syncStatus = .synced
            }
        } catch {
            if let i = store.companyCostCodes.firstIndex(where: { $0.id == code.id }) {
                store.companyCostCodes[i].syncStatus = .failed
            }
        }
    }

    /// Second-pass audit fix: bulk-flush every locally-pending cost
    /// code. Pre-fix `toggleCostCode()` set `syncStatus = .pending`
    /// but `pushPending()` never called any helper to drain the
    /// queue, so toggles silently never reached the server.
    func pushPendingCompanyCostCodes() async {
        let pending = store.companyCostCodes.filter { $0.syncStatus == .pending }
        guard !pending.isEmpty else { return }
        for code in pending {
            await pushCostCode(code)
        }
    }

    func deleteCostCode(_ code: CompanyCostCode) async {
        do {
            try await supabase
                .from(SupabaseTable.companyCostCodes)
                .delete()
                .eq("id", value: code.id.uuidString)
                .execute()
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    // MARK: - Material Sales Sync

    func pullMaterialSales() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, sale_number, sale_type, status, client_id: String
                let contact_id, site_id, opportunity_id, quote_id, invoice_id, project_id: String?
                let delivery_address: String?
                let requested_delivery_date: String?
                let line_items_json: String?
                let tax_rate: Double
                let notes: String?
                let is_deleted: Bool
                let deleted_at, deleted_by: String?
                let created_at, updated_at: String?
                let last_modified_by: String?
                /// material_sale_terms ledger flag — optional for legacy
                /// rows pre-dating the migration.
                let terms_default_applied: Bool?
                /// Customer acceptance audit field — set by the
                /// accept_material_sale_via_token RPC. Pull-only.
                let accepted_at: String?
            }
            let rows: [Row] = try await client.select(
                Row.self,
                from: SupabaseTable.materialSales,
                filters: [
                    .eq("company_id", companyID.uuidString),
                    .eq("is_deleted", false)
                ],
                orderBy: "created_at",
                ascending: false
            )

            let isoFmt = ISO8601DateFormatter()
            isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "yyyy-MM-dd"

            func parseDate(_ s: String?) -> Date? {
                guard let s = s else { return nil }
                return isoFmt.date(from: s) ?? dateFmt.date(from: s)
            }

            // Include .failed so push-rejected material sales aren't silently lost.
            var merged = store.materialSales.filter {
                $0.syncStatus == .pending || $0.syncStatus == .local || $0.syncStatus == .failed
            }
            for row in rows {
                guard let uuid     = UUID(uuidString: row.id),
                      let clientID = UUID(uuidString: row.client_id) else { continue }
                var sale = MaterialSale(clientID: clientID)
                sale.id              = uuid
                sale.saleNumber      = row.sale_number
                sale.saleType        = SaleType(rawValue: row.sale_type) ?? .materialSale
                sale.status          = MaterialSaleStatus(rawValue: row.status) ?? .draft
                sale.contactID       = row.contact_id.flatMap   { UUID(uuidString: $0) }
                sale.siteID          = row.site_id.flatMap      { UUID(uuidString: $0) }
                sale.opportunityID   = row.opportunity_id.flatMap { UUID(uuidString: $0) }
                sale.quoteID         = row.quote_id.flatMap     { UUID(uuidString: $0) }
                sale.invoiceID       = row.invoice_id.flatMap   { UUID(uuidString: $0) }
                sale.projectID       = row.project_id.flatMap   { UUID(uuidString: $0) }
                sale.deliveryAddress = row.delivery_address
                sale.requestedDeliveryDate = parseDate(row.requested_delivery_date)
                sale.taxRate         = Decimal(row.tax_rate)
                sale.notes           = row.notes
                sale.isDeleted       = row.is_deleted
                sale.deletedAt       = parseDate(row.deleted_at)
                sale.deletedBy       = row.deleted_by
                sale.createdAt       = parseDate(row.created_at) ?? Date()
                sale.updatedAt       = parseDate(row.updated_at) ?? Date()
                sale.lastModifiedBy  = row.last_modified_by ?? ""
                sale.termsDefaultApplied = row.terms_default_applied ?? false
                sale.acceptedAt          = parseDate(row.accepted_at)
                sale.syncStatus      = .synced
                if let json = row.line_items_json,
                   let data = json.data(using: .utf8),
                   let items = try? JSONDecoder().decode([MaterialSaleLineItem].self, from: data) {
                    sale.lineItems = items
                }
                merged.removeAll { $0.id == uuid }
                merged.append(sale)
            }
            store.materialSales = merged
            store.objectWillChange.send()

            // Signed-PDF generation: for every sale that has been
            // accepted (acceptedAt != nil), ensure a signed PDF +
            // Acceptance Certificate page exists locally and has
            // been emailed to the customer + company. The generator
            // is idempotent (UserDefaults ledger keyed on sale.id),
            // so this loop is safe to run on every pull — already-
            // processed sales are filtered before any network calls.
            let acceptedSales = await MainActor.run {
                store.materialSales.filter { $0.acceptedAt != nil && !$0.isDeleted }
            }
            for s in acceptedSales {
                await SignedMaterialSalePDFGenerator.shared.ensureSignedPDF(for: s, store: store)
            }
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    func pushPendingMaterialSales() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.materialSales.filter { $0.syncStatus == .pending }
        guard !pending.isEmpty else { return }

        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"

        for sale in pending {
            do {
                let lineItemsJSON: String = {
                    let enc = JSONEncoder()
                    enc.dateEncodingStrategy = .iso8601
                    return (try? enc.encode(sale.lineItems)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                }()
                struct Row: Encodable {
                    let id, company_id, sale_number, sale_type, status, client_id: String
                    let contact_id, site_id, opportunity_id, quote_id, invoice_id, project_id: String?
                    let delivery_address: String?
                    let requested_delivery_date: String?
                    let line_items_json: String
                    let tax_rate: Double
                    let notes: String?
                    let last_modified_by: String?
                    let is_deleted: Bool
                    let deleted_at, deleted_by: String?
                    let created_at, updated_at: String
                    /// material_sale_terms ledger flag.
                    let terms_default_applied: Bool
                }
                let row = Row(
                    id:                        sale.id.uuidString,
                    company_id:                companyID.uuidString,
                    sale_number:               sale.saleNumber,
                    sale_type:                 sale.saleType.rawValue,
                    status:                    sale.status.rawValue,
                    client_id:                 sale.clientID.uuidString,
                    contact_id:                sale.contactID?.uuidString,
                    site_id:                   sale.siteID?.uuidString,
                    opportunity_id:            sale.opportunityID?.uuidString,
                    quote_id:                  sale.quoteID?.uuidString,
                    invoice_id:                sale.invoiceID?.uuidString,
                    project_id:                sale.projectID?.uuidString,
                    delivery_address:          sale.deliveryAddress,
                    requested_delivery_date:   sale.requestedDeliveryDate.map { dateFmt.string(from: $0) },
                    line_items_json:           lineItemsJSON,
                    tax_rate:                  NSDecimalNumber(decimal: sale.taxRate).doubleValue,
                    notes:                     sale.notes,
                    last_modified_by:          sale.lastModifiedBy.isEmpty ? nil : sale.lastModifiedBy,
                    is_deleted:                sale.isDeleted,
                    deleted_at:                sale.deletedAt.map { isoFmt.string(from: $0) },
                    deleted_by:                sale.deletedBy,
                    created_at:                isoFmt.string(from: sale.createdAt),
                    updated_at:                isoFmt.string(from: sale.updatedAt),
                    terms_default_applied:     sale.termsDefaultApplied
                )
                try await client.upsert(row, into: SupabaseTable.materialSales)
                if let i = store.materialSales.firstIndex(where: { $0.id == sale.id }) {
                    store.materialSales[i].syncStatus = .synced
                }
                store.materialSales.removeAll { $0.isDeleted && $0.syncStatus == .synced }
                await MainActor.run { store.clearSyncError(id: sale.id) }
            } catch {
                if let i = store.materialSales.firstIndex(where: { $0.id == sale.id }) {
                    store.materialSales[i].syncStatus = .failed
                }
                await MainActor.run { store.recordSyncError(id: sale.id, error: error) }
                CrashReporter.capture(error: error, context: [
                    "operation":   "pushPendingMaterialSales",
                    "sale_id":      sale.id.uuidString,
                    "sale_number":  sale.saleNumber
                ])
            }
        }
        store.objectWillChange.send()
    }

    // MARK: - Import Batches (Audit Log)

    func pushImportBatch(_ batch: ImportBatch) async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            let payload: [String: AnyJSON] = [
                "id":               .string(batch.id.uuidString),
                "company_id":       .string(companyID.uuidString),
                "uploaded_by":      .string(batch.uploadedBy.uuidString),
                "file_name":        .string(batch.fileName),
                "record_type":      .string(batch.recordType),
                "status":           .string(batch.status.rawValue),
                "template_version": .string(batch.templateVersion),
                "total_rows":       .double(Double(batch.totalRows)),
                "created_count":    .double(Double(batch.created)),
                "updated_count":    .double(Double(batch.updated)),
                "skipped_count":    .double(Double(batch.skipped)),
                "error_count":      .double(Double(batch.errorCount)),
            ]
            try await client.upsert(payload, into: SupabaseTable.importBatches)
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }
}

// MARK: - Cost Code Row (Supabase decode helper)

private struct CostCodeRow: Decodable {
    let id: UUID
    let code: String
    let description: String
    let category: String
    let is_enabled: Bool
    let is_custom: Bool
    let sort_order: Int
    /// Slice C: nullable to stay backward-compat with rows created
    /// before the column existed (they decode to nil → empty array).
    let service_types: [String]?
}

// MARK: - Date Helpers

private let _syncDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

extension Date {
    var iso8601Date: String { _syncDateFormatter.string(from: self) }
}

/// Precision-safe Double → Decimal via string round-trip.
private func fromDouble(_ value: Double) -> Decimal {
    Decimal(string: String(value)) ?? 0
}
