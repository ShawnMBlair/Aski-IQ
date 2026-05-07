// TimesheetApprovalQueueView.swift
// FieldOS – Timesheet Approval Queue (Office Role)
// Replaces the stub in SharedComponents.swift

import SwiftUI

// Which sheet is currently active
private enum ApprovalSheet: Identifiable {
    case detail(TimesheetEntry)
    case reject(TimesheetEntry)
    var id: String {
        switch self {
        case .detail(let e): return "detail-\(e.id)"
        case .reject(let e): return "reject-\(e.id)"
        }
    }
}

struct TimesheetApprovalQueueView: View {
    @EnvironmentObject var store: AppStore
    @State private var filterProjectID: UUID? = nil
    @State private var activeSheet: ApprovalSheet? = nil
    @State private var rejectReason = ""

    // Bulk select mode
    @State private var isSelecting: Bool = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var bulkRejectReason: String = ""
    @State private var showBulkReject: Bool = false

    private var pending: [TimesheetEntry] {
        store.timesheetEntries
            .filter { $0.approvalStatus == .submitted }
            .filter { filterProjectID == nil || $0.projectID == filterProjectID }
            .sorted { $0.date > $1.date }
    }

    private var groupedByDate: [(String, [TimesheetEntry])] {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        let groups = Dictionary(grouping: pending) {
            formatter.string(from: $0.date)
        }
        return groups.sorted { $0.key > $1.key }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // MARK: - Project Filter
                if !store.projects.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            FilterChip(label: "All Projects", isSelected: filterProjectID == nil) {
                                filterProjectID = nil
                            }
                            ForEach(store.projects.filter { $0.status == .active }) { project in
                                FilterChip(
                                    label: project.name,
                                    isSelected: filterProjectID == project.id
                                ) {
                                    filterProjectID = filterProjectID == project.id ? nil : project.id
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                    }
                    Divider()
                }

                if pending.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 52))
                            .foregroundColor(.green)
                        Text("All caught up.")
                            .font(.headline)
                        Text("No timesheets pending approval.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(groupedByDate, id: \.0) { dateString, entries in
                            Section(dateString) {
                                ForEach(entries) { entry in
                                    HStack(spacing: 8) {
                                        if isSelecting {
                                            Image(systemName: selectedIDs.contains(entry.id)
                                                  ? "checkmark.circle.fill"
                                                  : "circle")
                                                .font(.title3)
                                                .foregroundColor(selectedIDs.contains(entry.id) ? .blue : .secondary)
                                                .accessibilityLabel(selectedIDs.contains(entry.id) ? "Selected" : "Not selected")
                                                .onTapGesture { toggleSelection(entry.id) }
                                        }
                                        ApprovalEntryRow(entry: entry) {
                                            if isSelecting { toggleSelection(entry.id) } else { approve(entry) }
                                        } onReject: {
                                            if isSelecting {
                                                toggleSelection(entry.id)
                                            } else {
                                                rejectReason = ""
                                                activeSheet = .reject(entry)
                                            }
                                        } onTap: {
                                            if isSelecting {
                                                toggleSelection(entry.id)
                                            } else {
                                                activeSheet = .detail(entry)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)

                    // Bulk action bar — appears at bottom while in selection mode.
                    if isSelecting && !selectedIDs.isEmpty {
                        HStack(spacing: 12) {
                            Button {
                                bulkApprove()
                            } label: {
                                Label("Approve \(selectedIDs.count)", systemImage: "checkmark.circle.fill")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)

                            Button {
                                bulkRejectReason = ""
                                showBulkReject = true
                            } label: {
                                Label("Reject \(selectedIDs.count)", systemImage: "xmark.circle.fill")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                        .background(Color(.systemBackground))
                    }
                }
            }
            .navigationTitle("Approval Queue")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await store.refreshAll() }
            .toolbar {
                if pending.count > 1 {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        if isSelecting {
                            Button("Done") {
                                isSelecting = false
                                selectedIDs.removeAll()
                            }
                        } else {
                            Menu {
                                Button("Select Multiple", systemImage: "checkmark.circle") {
                                    isSelecting = true
                                }
                                Button("Approve All", systemImage: "checkmark.seal") {
                                    approveAll()
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .accessibilityLabel("More actions")
                        }
                    }
                }
            }
            .sheet(isPresented: $showBulkReject) {
                RejectReasonSheet(reason: $bulkRejectReason) {
                    bulkReject(reason: bulkRejectReason)
                    showBulkReject = false
                }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .detail(let entry):
                    TimesheetDetailView(entry: entry)
                case .reject(let entry):
                    RejectReasonSheet(reason: $rejectReason) {
                        reject(entry, reason: rejectReason)
                        activeSheet = nil
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func approve(_ entry: TimesheetEntry) {
        guard store.requireRole(
            [.foreman, .projectManager, .officeAdmin, .manager, .executive],
            action: "approve timesheet"
        ) else {
            Haptics.error()
            ToastService.shared.error("Permission denied",
                                      body: "Your role can't approve timesheets.")
            return
        }
        var updated = entry
        updated.approvalStatus = .approved
        updated.approvedAt = Date()
        updated.approvedBy = store.currentUser?.fullName ?? "Office"
        updated.syncStatus = .pending
        updated.lastModifiedAt = Date()
        store.upsertTimesheetEntry(updated)
        store.createAuditSnapshot(for: updated, eventType: "approved", by: updated.approvedBy ?? "Office")

        Haptics.success()
        let employeeName = store.employee(id: entry.employeeID)?.fullName ?? "Timesheet"
        ToastService.shared.success("Approved",
                                    body: "\(employeeName) — \(entry.totalHours.description) hrs")

        // Cancel reminder if queue is now empty
        if pending.count == 0 {
            NotificationManager.shared.cancelDailyApprovalReminder()
        }
    }

    private func reject(_ entry: TimesheetEntry, reason: String) {
        guard store.requireRole(
            [.foreman, .projectManager, .officeAdmin, .manager, .executive],
            action: "reject timesheet"
        ) else {
            Haptics.error()
            ToastService.shared.error("Permission denied",
                                      body: "Your role can't reject timesheets.")
            return
        }
        var updated = entry
        updated.approvalStatus = .rejected
        updated.rejectionReason = reason.isEmpty ? "No reason provided" : reason
        updated.syncStatus = .pending
        updated.lastModifiedAt = Date()
        store.upsertTimesheetEntry(updated)
        store.createAuditSnapshot(
            for: updated,
            eventType: "rejected",
            by: store.currentUser?.fullName ?? "Office"
        )

        Haptics.medium()
        let employeeName = store.employee(id: entry.employeeID)?.fullName ?? "Timesheet"
        ToastService.shared.warning("Rejected",
                                    body: "\(employeeName) — \(reason.isEmpty ? "no reason" : reason)")
    }

    private func approveAll() {
        for entry in pending { approve(entry) }
    }

    // MARK: - Bulk

    private func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) }
        else { selectedIDs.insert(id) }
    }

    private func bulkApprove() {
        guard store.requireRole(
            [.foreman, .projectManager, .officeAdmin, .manager, .executive],
            action: "approve timesheet"
        ) else {
            Haptics.error()
            ToastService.shared.error("Permission denied")
            return
        }
        let targets = pending.filter { selectedIDs.contains($0.id) }
        let approver = store.currentUser?.fullName ?? "Office"
        for entry in targets {
            var updated = entry
            updated.approvalStatus = .approved
            updated.approvedAt = Date()
            updated.approvedBy = approver
            updated.syncStatus = .pending
            updated.lastModifiedAt = Date()
            store.upsertTimesheetEntry(updated)
            store.createAuditSnapshot(for: updated, eventType: "approved", by: approver)
        }
        selectedIDs.removeAll()
        isSelecting = false
        if pending.isEmpty {
            NotificationManager.shared.cancelDailyApprovalReminder()
        }
        Haptics.success()
        ToastService.shared.success("Approved \(targets.count) timesheet\(targets.count == 1 ? "" : "s")")
    }

    private func bulkReject(reason: String) {
        guard store.requireRole(
            [.foreman, .projectManager, .officeAdmin, .manager, .executive],
            action: "reject timesheet"
        ) else {
            Haptics.error()
            ToastService.shared.error("Permission denied")
            return
        }
        let targets = pending.filter { selectedIDs.contains($0.id) }
        let by = store.currentUser?.fullName ?? "Office"
        let resolved = reason.isEmpty ? "No reason provided" : reason
        for entry in targets {
            var updated = entry
            updated.approvalStatus = .rejected
            updated.rejectionReason = resolved
            updated.syncStatus = .pending
            updated.lastModifiedAt = Date()
            store.upsertTimesheetEntry(updated)
            store.createAuditSnapshot(for: updated, eventType: "rejected", by: by)
        }
        selectedIDs.removeAll()
        isSelecting = false
        Haptics.medium()
        ToastService.shared.warning("Rejected \(targets.count) timesheet\(targets.count == 1 ? "" : "s")",
                                    body: resolved)
    }
}

// MARK: - Approval Entry Row

struct ApprovalEntryRow: View {
    let entry: TimesheetEntry
    let onApprove: () -> Void
    let onReject: () -> Void
    let onTap: () -> Void

    @EnvironmentObject var store: AppStore

    private var employeeName: String {
        store.employee(id: entry.employeeID)?.fullName ?? "Unknown"
    }
    private var projectName: String {
        store.project(id: entry.projectID)?.name ?? "Unknown"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(employeeName).font(.headline)
                    Text(projectName).font(.subheadline).foregroundColor(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(entry.totalHours) hrs")
                        .font(.headline)
                        .bold()
                    if entry.overtimeHours > 0 {
                        Text("\(entry.overtimeHours) OT")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }

            if let task = entry.taskDescription {
                Text(task).font(.caption).foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    onReject()
                } label: {
                    Label("Reject", systemImage: "xmark.circle")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.1))
                        .foregroundColor(.red)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button {
                    onApprove()
                } label: {
                    Label("Approve", systemImage: "checkmark.circle")
                        .font(.subheadline)
                        .bold()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.green.opacity(0.15))
                        .foregroundColor(.green)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

// MARK: - Reject Reason Sheet

struct RejectReasonSheet: View {
    @Binding var reason: String
    let onConfirm: () -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Reason for Rejection") {
                    TextEditor(text: $reason)
                        .frame(minHeight: 100)
                }
            }
            .navigationTitle("Reject Timesheet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Reject") { onConfirm() }
                        .foregroundColor(.red)
                        .bold()
                }
            }
        }
        .presentationDetents([.medium])
    }
}
