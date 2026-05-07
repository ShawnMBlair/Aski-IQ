// WorkflowAutomation.swift
// Aski IQ – Workflow Rules Engine

import Foundation
import Combine
import UserNotifications

// MARK: - Trigger Type

enum WorkflowTrigger: String, Codable, CaseIterable {
    case invoiceOverdue          = "invoice_overdue"
    case invoiceUnpaidAfterDays  = "invoice_unpaid_after_days"
    case materialRequestSubmitted = "material_request_submitted"
    case materialRequestApproved  = "material_request_approved"
    case certExpiringSoon         = "cert_expiring_soon"
    case estimateStatusChanged    = "estimate_status_changed"
    case scheduleConflictDetected = "schedule_conflict_detected"
    case equipmentServiceDue      = "equipment_service_due"
    case incidentReported         = "incident_reported"
    case timesheetPendingTooLong  = "timesheet_pending_too_long"

    var displayName: String {
        switch self {
        case .invoiceOverdue:           return "Invoice Becomes Overdue"
        case .invoiceUnpaidAfterDays:   return "Invoice Unpaid After N Days"
        case .materialRequestSubmitted: return "Material Request Submitted"
        case .materialRequestApproved:  return "Material Request Approved"
        case .certExpiringSoon:         return "Certification Expiring Soon"
        case .estimateStatusChanged:    return "Estimate Status Changed"
        case .scheduleConflictDetected: return "Schedule Conflict Detected"
        case .equipmentServiceDue:      return "Equipment Service Due"
        case .incidentReported:         return "Incident Reported"
        case .timesheetPendingTooLong:  return "Timesheet Pending Too Long"
        }
    }

    var icon: String {
        switch self {
        case .invoiceOverdue:           return "exclamationmark.circle.fill"
        case .invoiceUnpaidAfterDays:   return "clock.badge.exclamationmark"
        case .materialRequestSubmitted: return "tray.and.arrow.up.fill"
        case .materialRequestApproved:  return "checkmark.circle.fill"
        case .certExpiringSoon:         return "checkmark.seal.fill"
        case .estimateStatusChanged:    return "doc.text.magnifyingglass"
        case .scheduleConflictDetected: return "exclamationmark.triangle.fill"
        case .equipmentServiceDue:      return "wrench.and.screwdriver.fill"
        case .incidentReported:         return "exclamationmark.shield.fill"
        case .timesheetPendingTooLong:  return "clock.fill"
        }
    }

    var category: WorkflowCategory {
        switch self {
        case .invoiceOverdue, .invoiceUnpaidAfterDays: return .financial
        case .materialRequestSubmitted, .materialRequestApproved: return .procurement
        case .certExpiringSoon: return .compliance
        case .estimateStatusChanged: return .commercial
        case .scheduleConflictDetected: return .scheduling
        case .equipmentServiceDue: return .equipment
        case .incidentReported: return .safety
        case .timesheetPendingTooLong: return .payroll
        }
    }
}

enum WorkflowCategory: String, Codable, CaseIterable {
    case financial   = "financial"
    case procurement = "procurement"
    case compliance  = "compliance"
    case commercial  = "commercial"
    case scheduling  = "scheduling"
    case equipment   = "equipment"
    case safety      = "safety"
    case payroll     = "payroll"

    var displayName: String { rawValue.capitalized }

    var color: String {
        switch self {
        case .financial:   return "orange"
        case .procurement: return "blue"
        case .compliance:  return "red"
        case .commercial:  return "purple"
        case .scheduling:  return "indigo"
        case .equipment:   return "teal"
        case .safety:      return "red"
        case .payroll:     return "green"
        }
    }
}

// MARK: - Action Type

enum WorkflowAction: String, Codable, CaseIterable {
    case pushNotification   = "push_notification"
    case inAppAlert         = "in_app_alert"
    case logAuditEvent      = "log_audit_event"
    case flagForReview      = "flag_for_review"

    var displayName: String {
        switch self {
        case .pushNotification: return "Send Push Notification"
        case .inAppAlert:       return "Show In-App Alert"
        case .logAuditEvent:    return "Log Audit Event"
        case .flagForReview:    return "Flag for Review"
        }
    }
}

// MARK: - Workflow Rule

struct WorkflowRule: Identifiable, Codable, Equatable {
    var id:            UUID   = UUID()
    var createdAt:     Date   = Date()
    var updatedAt:     Date   = Date()

    var name:          String
    var trigger:       WorkflowTrigger
    var action:        WorkflowAction  = .pushNotification
    var isEnabled:     Bool            = true
    var thresholdDays: Int             = 7     // Used by day-based triggers
    var notes:         String          = ""
    var lastFiredAt:   Date?           = nil
    var fireCount:     Int             = 0

    // MARK: - Sync scaffolding (added 2026-04 audit)
    // Previously lived only in UserDefaults so rules were invisible
    // across devices. Now mirrored into `workflow_rules` table —
    // these fields drive the same pull/push pipeline every other
    // BaseModel uses (companyID for RLS, syncStatus for queue,
    // isDeleted for soft-delete).
    var companyID:  UUID?      = nil
    var syncStatus: SyncStatus = .local
    var isDeleted:  Bool       = false

    init(name: String, trigger: WorkflowTrigger) {
        self.name    = name
        self.trigger = trigger
    }
}

// MARK: - Workflow Engine

final class WorkflowEngine {

    static let shared = WorkflowEngine()
    private init() {}

    /// Evaluate all enabled rules against current store state.
    /// Call after any significant state change (sync pull, approval, etc.).
    func evaluate(store: AppStore) {
        let rules = store.workflowRules.filter { $0.isEnabled }
        for rule in rules {
            fire(rule: rule, store: store)
        }
    }

    private func fire(rule: WorkflowRule, store: AppStore) {
        switch rule.trigger {

        case .invoiceOverdue:
            let overdue = store.overdueInvoices
            if !overdue.isEmpty {
                dispatch(rule: rule, store: store,
                         title: "Overdue Invoices",
                         body: "\(overdue.count) invoice\(overdue.count == 1 ? "" : "s") past due — total \(store.totalOutstanding.currencyString) outstanding.")
            }

        case .invoiceUnpaidAfterDays:
            let cutoff = Calendar.current.date(byAdding: .day, value: -rule.thresholdDays, to: Date()) ?? Date()
            let stale = store.openInvoices.filter { $0.invoiceDate < cutoff }
            if !stale.isEmpty {
                dispatch(rule: rule, store: store,
                         title: "Unpaid Invoices",
                         body: "\(stale.count) invoice\(stale.count == 1 ? "" : "s") unpaid for more than \(rule.thresholdDays) days.")
            }

        case .materialRequestSubmitted:
            let pending = store.pendingMaterialApprovals
            if !pending.isEmpty {
                dispatch(rule: rule, store: store,
                         title: "Material Approval Needed",
                         body: "\(pending.count) material request\(pending.count == 1 ? "" : "s") awaiting approval.")
            }

        case .materialRequestApproved:
            // Triggered externally via approveMaterialRequest — no polling needed
            break

        case .certExpiringSoon:
            let alerts = store.complianceAlerts
            if !alerts.isEmpty {
                dispatch(rule: rule, store: store,
                         title: "Certifications Expiring",
                         body: "\(alerts.count) certification\(alerts.count == 1 ? "" : "s") expiring within \(rule.thresholdDays) days.")
            }

        case .estimateStatusChanged:
            // Triggered on status change events — no polling
            break

        case .scheduleConflictDetected:
            let conflicts = store.criticalScheduleConflicts
            if !conflicts.isEmpty {
                dispatch(rule: rule, store: store,
                         title: "Schedule Conflicts",
                         body: "\(conflicts.count) critical scheduling conflict\(conflicts.count == 1 ? "" : "s") detected.")
            }

        case .equipmentServiceDue:
            let due = store.equipmentNeedingService
            if !due.isEmpty {
                dispatch(rule: rule, store: store,
                         title: "Equipment Service Due",
                         body: "\(due.count) piece\(due.count == 1 ? "" : "s") of equipment overdue for service.")
            }

        case .incidentReported:
            let open = store.openIncidents
            if !open.isEmpty {
                dispatch(rule: rule, store: store,
                         title: "Open Safety Incidents",
                         body: "\(open.count) open incident\(open.count == 1 ? "" : "s") requiring follow-up.")
            }

        case .timesheetPendingTooLong:
            let cutoff = Calendar.current.date(byAdding: .day, value: -rule.thresholdDays, to: Date()) ?? Date()
            let stale = store.pendingTimesheets().filter { $0.date < cutoff }
            if !stale.isEmpty {
                dispatch(rule: rule, store: store,
                         title: "Timesheets Pending Approval",
                         body: "\(stale.count) timesheet\(stale.count == 1 ? "" : "s") pending for more than \(rule.thresholdDays) days.")
            }
        }
    }

    private func dispatch(rule: WorkflowRule, store: AppStore, title: String, body: String) {
        switch rule.action {
        case .pushNotification:
            NotificationManager.shared.sendLocalNotification(title: title, body: body,
                                                              identifier: "workflow_\(rule.id)")
        case .inAppAlert:
            DispatchQueue.main.async {
                store.pendingWorkflowAlerts.append(WorkflowAlert(ruleID: rule.id, title: title, body: body))
            }
        case .logAuditEvent:
            // Lightweight — no BaseModel entity to snapshot, but the
            // log entry IS now server-synced (2026-04 audit fix), so
            // we stamp companyID + .pending here and let the next
            // pushPending() flush it.
            DispatchQueue.main.async {
                var entry = WorkflowLogEntry(ruleID: rule.id, ruleName: rule.name,
                                             title: title, body: body)
                entry.companyID  = store.currentCompanyID
                entry.syncStatus = .pending
                store.workflowLog.append(entry)
                Task { await SyncEngine.shared.pushPendingWorkflowLog() }
            }
        case .flagForReview:
            DispatchQueue.main.async {
                store.pendingWorkflowAlerts.append(WorkflowAlert(ruleID: rule.id, title: "⚑ \(title)", body: body))
            }
        }

        // Update fire stats
        DispatchQueue.main.async {
            if let idx = store.workflowRules.firstIndex(where: { $0.id == rule.id }) {
                store.workflowRules[idx].lastFiredAt = Date()
                store.workflowRules[idx].fireCount  += 1
            }
        }
    }
}

// MARK: - Supporting Types

/// Runtime alert fired when a workflow rule trips. Phase 1 Step 3 made
/// this Codable so live alerts survive force-quit via LocalPendingStore.
/// Properties stayed `var`-with-default so existing init call sites
/// (`WorkflowAlert(ruleID:title:body:)`) continue to compile unchanged.
struct WorkflowAlert: Identifiable, Codable {
    var id:      UUID = UUID()
    var ruleID:  UUID
    var title:   String
    var body:    String
    var firedAt: Date = Date()
}

struct WorkflowLogEntry: Identifiable, Codable {
    var id:        UUID   = UUID()
    var ruleID:    UUID
    var ruleName:  String
    var title:     String
    var body:      String
    var firedAt:   Date   = Date()

    // Sync scaffolding (2026-04 audit). Same rationale as WorkflowRule.
    // Note: `let` was widened to `var` so the sync layer can flip
    // `syncStatus` after a successful upsert.
    var companyID:  UUID?      = nil
    var syncStatus: SyncStatus = .local
    var isDeleted:  Bool       = false
}

// MARK: - NotificationManager helper (send arbitrary local notification)

extension NotificationManager {
    func sendLocalNotification(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

// MARK: - AppStore Extension

extension AppStore {

    // MARK: Workflow State (not persisted — rehydrated at launch)
    // workflowRules are persisted; alerts and log are session-only

    private static let workflowRulesKey = "bv_workflow_rules"
    private static let workflowLogKey   = "bv_workflow_log"

    func saveWorkflowRules() {
        if let data = try? JSONEncoder().encode(workflowRules) {
            UserDefaults.standard.set(data, forKey: AppStore.workflowRulesKey)
        }
    }

    func loadWorkflowRules() {
        if let data = UserDefaults.standard.data(forKey: AppStore.workflowRulesKey),
           let items = try? JSONDecoder().decode([WorkflowRule].self, from: data) {
            workflowRules = items
        } else {
            workflowRules = WorkflowEngine.defaultRules()
        }
    }

    func saveWorkflowLog() {
        if let data = try? JSONEncoder().encode(workflowLog) {
            UserDefaults.standard.set(data, forKey: AppStore.workflowLogKey)
        }
    }

    func loadWorkflowLog() {
        if let data = UserDefaults.standard.data(forKey: AppStore.workflowLogKey),
           let items = try? JSONDecoder().decode([WorkflowLogEntry].self, from: data) {
            workflowLog = Array(items.suffix(500))   // Keep last 500 log entries
        }
    }

    func addWorkflowRule(_ rule: WorkflowRule) {
        guard requireRole([.officeAdmin, .manager, .executive], action: "add_workflow_rule") else { return }
        // Stamp tenant + sync state so the row makes it to the
        // server on the next pushPending(). Without this the row
        // would stay `.local` and never sync (was the pre-2026-04
        // behavior — all rules died on UserDefaults).
        var stamped = rule
        if stamped.companyID == nil { stamped.companyID = currentCompanyID }
        stamped.syncStatus     = .pending
        stamped.updatedAt      = Date()
        objectWillChange.send()
        workflowRules.append(stamped)
        saveWorkflowRules()
        Task { await SyncEngine.shared.pushPendingWorkflowRules() }
    }

    func updateWorkflowRule(_ rule: WorkflowRule) {
        guard requireRole([.officeAdmin, .manager, .executive], action: "update_workflow_rule") else { return }
        var stamped = rule
        if stamped.companyID == nil { stamped.companyID = currentCompanyID }
        stamped.syncStatus = .pending
        stamped.updatedAt  = Date()
        objectWillChange.send()
        if let idx = workflowRules.firstIndex(where: { $0.id == stamped.id }) {
            workflowRules[idx] = stamped
        }
        saveWorkflowRules()
        Task { await SyncEngine.shared.pushPendingWorkflowRules() }
    }

    func deleteWorkflowRule(id: UUID) {
        guard requireRole([.officeAdmin, .manager, .executive], action: "delete_workflow_rule") else { return }
        objectWillChange.send()
        // Soft-delete + push so the deletion propagates server-side
        // instead of just disappearing from this device.
        if let idx = workflowRules.firstIndex(where: { $0.id == id }) {
            workflowRules[idx].isDeleted  = true
            workflowRules[idx].syncStatus = .pending
            workflowRules[idx].updatedAt  = Date()
        }
        saveWorkflowRules()
        Task { await SyncEngine.shared.pushPendingWorkflowRules() }
    }

    func runWorkflowEngine() {
        WorkflowEngine.shared.evaluate(store: self)
    }
}

extension WorkflowEngine {
    /// The default rule set loaded on first launch.
    static func defaultRules() -> [WorkflowRule] {
        var rules: [WorkflowRule] = []

        var r1 = WorkflowRule(name: "Invoice Overdue Alert", trigger: .invoiceOverdue)
        r1.action = .pushNotification
        rules.append(r1)

        var r2 = WorkflowRule(name: "Invoice Unpaid 14 Days", trigger: .invoiceUnpaidAfterDays)
        r2.action = .inAppAlert
        r2.thresholdDays = 14
        rules.append(r2)

        var r3 = WorkflowRule(name: "Material Request Approval", trigger: .materialRequestSubmitted)
        r3.action = .pushNotification
        rules.append(r3)

        var r4 = WorkflowRule(name: "Certification Expiry Warning", trigger: .certExpiringSoon)
        r4.action = .pushNotification
        r4.thresholdDays = 30
        rules.append(r4)

        var r5 = WorkflowRule(name: "Schedule Conflict Alert", trigger: .scheduleConflictDetected)
        r5.action = .inAppAlert
        rules.append(r5)

        var r6 = WorkflowRule(name: "Equipment Service Overdue", trigger: .equipmentServiceDue)
        r6.action = .pushNotification
        rules.append(r6)

        var r7 = WorkflowRule(name: "Incident Follow-Up", trigger: .incidentReported)
        r7.action = .logAuditEvent
        rules.append(r7)

        var r8 = WorkflowRule(name: "Timesheet Approval Reminder", trigger: .timesheetPendingTooLong)
        r8.action = .pushNotification
        r8.thresholdDays = 3
        rules.append(r8)

        return rules
    }
}
