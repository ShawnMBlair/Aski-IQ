// NotificationManager.swift
// BV APP – Local Notifications (Sprint 12)

#if canImport(UIKit)
import UserNotifications
import UIKit

// MARK: - Deep Link Routing

/// A category of destination a tapped notification should send the user to.
/// Stored on each UNNotificationContent.userInfo as `notif_route`.
enum NotifRoute: String {
    case approvalQueue     = "approval_queue"
    case djrApprovalQueue  = "djr_approval"
    case incidentList      = "incident_list"
    case certificationList = "cert_list"
    case equipmentList     = "equipment_list"
    case estimateList      = "estimate_list"
    case invoiceList       = "invoice_list"
    case crmTasks          = "crm_tasks"
    case crmHub            = "crm_hub"
}

/// Notification tap delegate. Apple requires the delegate to be NSObject-conforming
/// so it lives separately from the @MainActor NotificationManager class.
final class NotificationTapDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationTapDelegate()
    override private init() { super.init() }

    /// Show banner + play sound even when the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    /// User tapped a notification. Read `notif_route` from userInfo and
    /// publish it via AppStore.pendingDeepLink so RootView can react.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let info = response.notification.request.content.userInfo
        guard let raw = info["notif_route"] as? String,
              let route = NotifRoute(rawValue: raw) else { return }
        Task { @MainActor in
            AppStore.shared.pendingDeepLink = route
        }
    }
}

// MARK: - Notification Manager

@MainActor
final class NotificationManager {

    static let shared = NotificationManager()
    private init() {}

    // Notification identifiers
    private let approvalReminderID = "bv.approvals.daily"
    private let newSubmissionID    = "bv.timesheets.submitted"

    // MARK: - Authorization

    /// Call once on app launch — asks for alert + badge + sound permission
    func requestAuthorization() {
        // Install the tap delegate before requesting permission so any taps
        // on already-delivered notifications are routed correctly.
        UNUserNotificationCenter.current().delegate = NotificationTapDelegate.shared
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        ) { granted, _ in
            if granted {
                Task { @MainActor in
                    self.syncBadge()
                }
            }
        }
    }

    // MARK: - Badge Sync
    /// Call whenever pending timesheet count changes.
    /// Updates the app icon badge immediately.

    func syncBadge(pendingCount: Int? = nil) {
        let count = pendingCount ?? AppStore.shared.pendingTimesheets().count
        UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
    }

    // MARK: - New Submission Notification
    /// Fires ~2 seconds after a foreman submits timesheets.
    /// Visible to office users when app is in background.

    func notifySubmitted(employeeName: String, hours: String, projectName: String) {
        let content          = UNMutableNotificationContent()
        content.title        = "⏱ New Hours Submitted"
        content.body         = "\(employeeName) submitted \(hours) hrs on \(projectName)"
        content.sound        = .default
        content.userInfo     = ["notif_route": NotifRoute.approvalQueue.rawValue]
        content.badge        = NSNumber(value: AppStore.shared.pendingTimesheets().count + 1)

        let trigger  = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        let id       = "\(newSubmissionID).\(UUID().uuidString)"
        let request  = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Daily Approval Reminder
    /// Schedules a repeating daily notification at 8:00 AM if there are pending approvals.
    /// Replaced each time pending count changes so the body stays accurate.
    /// Cancelled automatically when the queue is empty.

    func scheduleDailyApprovalReminder(pendingCount: Int) {
        // Cancel existing before rescheduling
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [approvalReminderID])

        guard pendingCount > 0 else { return }

        let content       = UNMutableNotificationContent()
        content.title     = "📋 Timesheets Pending Approval"
        let plural        = pendingCount == 1 ? "timesheet needs" : "timesheets need"
        content.body      = "\(pendingCount) \(plural) your review."
        content.sound     = .default
        content.userInfo  = ["notif_route": NotifRoute.approvalQueue.rawValue]
        content.badge     = NSNumber(value: pendingCount)

        // Fire at 8:00 AM every day
        var comps         = DateComponents()
        comps.hour        = 8
        comps.minute      = 0
        let trigger       = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        let request       = UNNotificationRequest(
            identifier: approvalReminderID,
            content:    content,
            trigger:    trigger
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Expiring Certification Alert

    /// Spam-fix 2026-05: callers now pass a stable `certificateID` so
    /// re-running the compliance sweep on every sync REPLACES the
    /// pending notification instead of stacking a new UUID each time.
    /// Layered with a once-per-day throttle (`shouldFireToday(...)`)
    /// so even if the same cert id is re-issued, the user sees one
    /// alert per day per cert at most.
    func notifyExpiringCertificate(certificateID: UUID,
                                   employeeName: String,
                                   certName: String,
                                   daysLeft: Int) {
        let key = "bv.cert.expiring.\(certificateID.uuidString)"
        guard shouldFireToday(key: key) else { return }

        let content       = UNMutableNotificationContent()
        content.title     = "⚠️ Certification Expiring Soon"
        content.body      = "\(employeeName)'s \(certName) expires in \(daysLeft) day\(daysLeft == 1 ? "" : "s")"
        content.sound     = .default
        content.userInfo  = ["notif_route": NotifRoute.certificationList.rawValue]

        let trigger  = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        let request  = UNNotificationRequest(identifier: key, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
        markFiredToday(key: key)
    }

    // MARK: - High / Critical Incident Alert
    /// Fires immediately when a high or critical incident is reported.
    /// Intended for management-role users who have the app in background.

    func notifyHighSeverityIncident(title: String, severity: String, project: String) {
        let content       = UNMutableNotificationContent()
        content.title     = "🚨 \(severity.uppercased()) Severity Incident"
        content.body      = "\(title) — \(project)"
        content.sound     = .defaultCritical
        content.userInfo  = ["notif_route": NotifRoute.incidentList.rawValue]
        content.badge     = NSNumber(value: AppStore.shared.openIncidents.count)

        let trigger  = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let id       = "bv.incident.highseverity.\(UUID().uuidString)"
        let request  = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Estimate Review Requested
    /// Fires when an estimator submits an estimate for internal review and
    /// designates a reviewer. Local-only for beta — visible to anyone with
    /// the app foregrounded/backgrounded; doesn't push cross-device. Tap
    /// routes to the Estimate list; the assigned estimate appears with the
    /// reviewer's name stamped in `internal_review_by` for filtering.

    func notifyEstimateReviewRequested(reviewerName: String, estimateName: String, estimateJobNumber: String) {
        let content       = UNMutableNotificationContent()
        content.title     = "📝 Estimate Needs Review"
        content.body      = "\(reviewerName) — please review \(estimateJobNumber): \(estimateName)"
        content.sound     = .default
        content.userInfo  = ["notif_route": NotifRoute.estimateList.rawValue]

        let trigger  = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        let id       = "bv.estimate.review.\(UUID().uuidString)"
        let request  = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    /// Cancel the daily reminder (call when approval queue is cleared)
    func cancelDailyApprovalReminder() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [approvalReminderID])
        syncBadge(pendingCount: 0)
    }

    // MARK: - DJR Submitted
    /// Fires when a field worker submits a Daily Job Report.
    /// Visible to project managers / foremen who can approve.

    func notifyDJRSubmitted(reportNumber: String, projectName: String, submittedBy: String) {
        let content       = UNMutableNotificationContent()
        content.title     = "📋 Daily Report Submitted"
        content.body      = "\(submittedBy) submitted \(reportNumber) for \(projectName)"
        content.sound     = .default
        content.userInfo  = ["notif_route": NotifRoute.djrApprovalQueue.rawValue]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        let id      = "bv.djr.submitted.\(UUID().uuidString)"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        )
    }

    // MARK: - Equipment Service Due
    /// Fire when equipment's next service date is within 14 days.

    /// Spam-fix 2026-05: stable id per equipment item + once-per-day
    /// throttle. Same rationale as `notifyExpiringCertificate`.
    func notifyEquipmentServiceDue(equipmentID: UUID,
                                   name: String,
                                   daysUntilDue: Int) {
        let key = "bv.equipment.service.\(equipmentID.uuidString)"
        guard shouldFireToday(key: key) else { return }

        let content       = UNMutableNotificationContent()
        content.title     = "🔧 Equipment Service Due"
        let when          = daysUntilDue == 0 ? "today" :
                            daysUntilDue < 0  ? "\(abs(daysUntilDue)) days overdue" :
                                                "in \(daysUntilDue) day\(daysUntilDue == 1 ? "" : "s")"
        content.body      = "\(name) is due for service \(when)"
        content.sound     = .default
        content.userInfo  = ["notif_route": NotifRoute.equipmentList.rawValue]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: key, content: content, trigger: trigger)
        )
        markFiredToday(key: key)
    }

    // MARK: - Scheduled Cert/Equipment Sweep
    /// Schedules a daily 7 AM sweep notification reminding about expiring certs/equipment.
    /// Call on login and after any cert update.

    func scheduleDailyCertSweep(expiringCount: Int) {
        let sweepID = "bv.certs.daily.sweep"
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [sweepID])
        guard expiringCount > 0 else { return }

        let content   = UNMutableNotificationContent()
        content.title = "⚠️ Compliance Alerts"
        let plural    = expiringCount == 1 ? "certification expires" : "certifications expire"
        content.body  = "\(expiringCount) \(plural) within 30 days — review in Certifications."
        content.sound = .default
        content.userInfo = ["notif_route": NotifRoute.certificationList.rawValue]

        var comps     = DateComponents()
        comps.hour    = 7
        comps.minute  = 0
        let trigger   = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: sweepID, content: content, trigger: trigger)
        )
    }

    // MARK: - Incident Opened
    /// Fires for any new open incident (already have high-severity; this covers all).

    func notifyIncidentOpened(title: String, projectName: String) {
        let content   = UNMutableNotificationContent()
        content.title = "🛡 New Incident Reported"
        content.body  = "\(title) — \(projectName)"
        content.sound = .default
        content.userInfo = ["notif_route": NotifRoute.incidentList.rawValue]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let id      = "bv.incident.new.\(UUID().uuidString)"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        )
    }

    // MARK: - Estimate Approved / Rejected

    func notifyEstimateStatusChanged(estimateName: String, status: String) {
        let content   = UNMutableNotificationContent()
        content.title = status == "approved" ? "✅ Estimate Approved" : "❌ Estimate Rejected"
        content.body  = "\(estimateName) has been \(status)"
        content.sound = .default
        content.userInfo = ["notif_route": NotifRoute.estimateList.rawValue]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        let id      = "bv.estimate.status.\(UUID().uuidString)"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        )
    }

    // MARK: - Overdue Invoice Reminder
    /// Schedules a daily 9 AM notification when overdue invoices exist.
    /// Re-called after every invoice update; cancels itself when queue is clear.

    func scheduleOverdueInvoiceReminder(overdueCount: Int, totalOwed: String) {
        let id = "bv.invoices.overdue.daily"
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        guard overdueCount > 0 else { return }

        let content   = UNMutableNotificationContent()
        content.title = "💰 Overdue Invoices"
        let plural    = overdueCount == 1 ? "invoice is" : "invoices are"
        content.body  = "\(overdueCount) \(plural) overdue — \(totalOwed) outstanding"
        content.sound = .default
        content.userInfo = ["notif_route": NotifRoute.invoiceList.rawValue]

        var comps     = DateComponents()
        comps.hour    = 9
        comps.minute  = 0
        let trigger   = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        )
    }

    // MARK: - CRM Task Notifications

    private let crmTaskReminderID = "bv.crm.tasks.daily"

    /// Fires when a task is newly assigned to the current user via server sync.
    func notifyCRMTaskAssigned(taskTitle: String, assignedBy: String) {
        let content   = UNMutableNotificationContent()
        content.title = "📌 New Task Assigned"
        content.body  = assignedBy.isEmpty ? taskTitle : "\(taskTitle) — assigned by \(assignedBy)"
        content.sound = .default
        content.userInfo = ["notif_route": NotifRoute.crmTasks.rawValue]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        let id      = "bv.crm.task.assigned.\(UUID().uuidString)"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        )
    }

    /// Schedules (or cancels) the repeating 8:30 AM daily CRM task reminder.
    func scheduleDailyCRMTaskReminder(overdueCount: Int, dueTodayCount: Int) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [crmTaskReminderID])
        let total = overdueCount + dueTodayCount
        guard total > 0 else { return }

        let content   = UNMutableNotificationContent()
        content.title = "📋 CRM Tasks Need Attention"
        var parts: [String] = []
        if overdueCount  > 0 { parts.append("\(overdueCount) overdue") }
        if dueTodayCount > 0 { parts.append("\(dueTodayCount) due today") }
        content.body  = parts.joined(separator: ", ")
        content.sound = .default
        content.userInfo = ["notif_route": NotifRoute.crmTasks.rawValue]

        var comps     = DateComponents()
        comps.hour    = 8
        comps.minute  = 30
        let trigger   = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: crmTaskReminderID, content: content, trigger: trigger)
        )
    }

    /// Called after each sync — fires immediate alerts for high/urgent tasks due today
    /// and refreshes the daily summary banner.
    func runCRMTaskSweep() {
        let store  = AppStore.shared
        let role   = store.currentUserRole
        guard role.canViewCRM else { return }

        let activeTasks: [CRMTask]
        if role.isFieldRole, let uid = store.currentUser?.id {
            activeTasks = store.crmTasks.filter { $0.assignedToID == uid && $0.status != .done }
        } else {
            activeTasks = store.crmTasks.filter { $0.status != .done }
        }

        let calendar  = Calendar.current
        let overdue   = activeTasks.filter { $0.isOverdue }
        let dueToday  = activeTasks.filter {
            guard let due = $0.dueDate else { return false }
            return calendar.isDateInToday(due)
        }

        // Immediate burst for high/urgent tasks due today (cap at 3 to avoid spam)
        let urgentToday = dueToday.filter { $0.priority == .high || $0.priority == .urgent }
        for (offset, task) in urgentToday.prefix(3).enumerated() {
            let content   = UNMutableNotificationContent()
            content.title = task.priority == .urgent
                ? "🚨 Urgent Task Due Today"
                : "⚠️ High Priority Task Due Today"
            content.body  = task.title
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: Double(offset) + 1.0, repeats: false
            )
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    identifier: "bv.crm.task.duetoday.\(task.id.uuidString)",
                    content: content,
                    trigger: trigger
                )
            )
        }

        scheduleDailyCRMTaskReminder(overdueCount: overdue.count, dueTodayCount: dueToday.count)
    }

    // MARK: - Compliance Sweep
    /// Run on app launch / after sync to fire pending cert/equipment alerts.

    func runComplianceSweep() {
        let store = AppStore.shared
        let today = Date()
        let calendar = Calendar.current

        // Expiring certs within 30 days. notifyExpiringCertificate
        // self-throttles to once per cert per day, so calling this
        // every sync is safe — it won't refire alerts already shown.
        for cert in store.complianceAlerts {
            guard let expiry = cert.expiryDate else { continue }
            let days = calendar.dateComponents([.day], from: today, to: expiry).day ?? 0
            if let emp = store.employee(id: cert.employeeID) {
                notifyExpiringCertificate(
                    certificateID: cert.id,
                    employeeName: emp.fullName,
                    certName: cert.displayName,
                    daysLeft: max(0, days)
                )
            }
        }

        // Equipment service due within 14 days. Self-throttled.
        for item in store.equipment where item.isActive {
            guard let next = item.nextServiceDate else { continue }
            let days = calendar.dateComponents([.day], from: today, to: next).day ?? 0
            if days <= 14 {
                notifyEquipmentServiceDue(
                    equipmentID: item.id,
                    name: item.name,
                    daysUntilDue: days
                )
            }
        }

        // Schedule the recurring cert sweep banner
        scheduleDailyCertSweep(expiringCount: store.complianceAlerts.count)

        // Schedule overdue invoice reminder
        let overdue = store.overdueInvoices
        let total   = overdue.reduce(Decimal(0)) { $0 + $1.balanceDue }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale.current
        let totalStr = formatter.string(from: total as NSDecimalNumber) ?? "\(overdue.count) invoices"
        scheduleOverdueInvoiceReminder(overdueCount: overdue.count, totalOwed: totalStr)

        // CRM task overdue / due-today sweep
        runCRMTaskSweep()
    }

    // MARK: - Once-per-day throttle (spam-fix 2026-05)
    //
    // The compliance sweep runs on every app launch + every sync, and
    // pre-fix re-issued the same cert/equipment notifications with
    // fresh UUID identifiers each time — so users got the same alert
    // 3-10× per day. This pair of helpers persists "last fired (day)"
    // per stable identifier in UserDefaults and skips re-fires within
    // the same calendar day. The store is bounded — keys older than 7
    // days get pruned on each call so the file doesn't grow forever.
    //
    // Why UserDefaults: the throttle is per-device UX preference, not
    // business data. No need for cross-device sync (in fact you WANT
    // each device to track its own "did I show this today" state).

    private static let firedTodayKey = "bv.notif.firedTodayMap"

    /// True when this identifier hasn't been fired yet today.
    /// Side-effect-free — pair with `markFiredToday(key:)` after the
    /// notification request is added.
    func shouldFireToday(key: String) -> Bool {
        let map = firedTodayMap()
        guard let lastFired = map[key] else { return true }
        return !Calendar.current.isDateInToday(lastFired)
    }

    /// Records that `key` fired today. Also prunes entries older than
    /// 7 days as a housekeeping pass — one prune cycle per fire is
    /// cheap and avoids the map growing unboundedly.
    func markFiredToday(key: String) {
        var map = firedTodayMap()
        map[key] = Date()
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        map = map.filter { $0.value >= cutoff }
        saveFiredTodayMap(map)
    }

    private func firedTodayMap() -> [String: Date] {
        guard let raw = UserDefaults.standard.data(forKey: Self.firedTodayKey),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: raw) else {
            return [:]
        }
        return decoded
    }

    private func saveFiredTodayMap(_ map: [String: Date]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: Self.firedTodayKey)
    }

    /// Manual reset — wired into the Settings screen later if needed
    /// for users who want to re-see all alerts. No-op here unless
    /// called from a UI affordance.
    func resetNotificationThrottle() {
        UserDefaults.standard.removeObject(forKey: Self.firedTodayKey)
    }
}
#endif
