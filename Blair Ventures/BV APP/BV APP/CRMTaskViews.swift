// CRMTaskViews.swift
// BV APP – CRM Task List, Full Detail, and supporting views

import SwiftUI
import Foundation

// MARK: - Date Formatter Helpers

private let shortDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMM d"
    return f
}()

private func shortDate(_ date: Date?) -> String {
    guard let date else { return "No date" }
    return shortDateFormatter.string(from: date)
}

// MARK: - Task Segment

private enum TaskSegment: String, CaseIterable {
    case all     = "All"
    case today   = "Today"
    case overdue = "Overdue"
}

// MARK: - CRMTaskListView (replaces stub in CRMHubView.swift)

struct CRMTaskListView: View {
    @EnvironmentObject var store: AppStore
    @State private var segment: TaskSegment = .all
    @State private var showAddTask: Bool = false
    @StateObject private var pagination = PaginationState(pageSize: 25)

    private var displayedTasks: [CRMTask] {
        switch segment {
        case .all:
            return store.crmTasks
                .filter { $0.status != .done }
                .sorted {
                    // Sort by dueDate ascending (nil last), then priority descending
                    switch ($0.dueDate, $1.dueDate) {
                    case let (a?, b?):
                        if a != b { return a < b }
                        return $0.priority.sortOrder > $1.priority.sortOrder
                    case (.some, .none): return true
                    case (.none, .some): return false
                    case (.none, .none): return $0.priority.sortOrder > $1.priority.sortOrder
                    }
                }
        case .today:
            return store.todayCRMTasks
        case .overdue:
            return store.overdueCRMTasks
        }
    }

    private var emptyIcon: String {
        switch segment {
        case .all:     return "checklist"
        case .today:   return "calendar.badge.clock"
        case .overdue: return "exclamationmark.triangle"
        }
    }

    private var emptyMessage: String {
        switch segment {
        case .all:     return "No open tasks.\nTap + to create one."
        case .today:   return "Nothing due today.\nEnjoy the breathing room."
        case .overdue: return "No overdue tasks.\nYou're all caught up!"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Segmented picker
            Picker("Filter", selection: $segment) {
                ForEach(TaskSegment.allCases, id: \.self) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .onChange(of: segment) { pagination.reset() }

            if displayedTasks.isEmpty {
                TaskEmptyState(icon: emptyIcon, message: emptyMessage)
            } else {
                List {
                    Section {
                        ForEach(Array(displayedTasks.prefix(pagination.displayLimit))) { task in
                            NavigationLink(destination: CRMTaskFullDetailView(task: task)) {
                                TaskListRow(task: task)
                                    .environmentObject(store)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if task.status != .done && store.currentUserRole.canEditCRM {
                                    Button {
                                        var updated = task
                                        updated.status = .done
                                        updated.completedAt = Date()
                                        store.upsertCRMTask(updated)
                                    } label: {
                                        Label("Done", systemImage: "checkmark.circle.fill")
                                    }
                                    .tint(.green)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if store.currentUserRole.canDeleteCRMTasks {
                                    Button(role: .destructive) {
                                        store.deleteCRMTask(task)
                                    } label: {
                                        Label("Delete", systemImage: "trash.fill")
                                    }
                                }
                            }
                        }
                        LoadMoreFooter(
                            showing: min(pagination.displayLimit, displayedTasks.count),
                            total: displayedTasks.count,
                            onLoad: { pagination.loadMore() }
                        )
                    } header: {
                        Text("\(displayedTasks.count) task\(displayedTasks.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Tasks")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if store.currentUserRole.canEditCRM {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddTask = true
                    } label: {
                        Label("Add Task", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showAddTask) {
            CRMTaskCreateSheet(clientID: nil, opportunityID: nil)
                .environmentObject(store)
        }
    }
}

// MARK: - Task List Row

private struct TaskListRow: View {
    @EnvironmentObject var store: AppStore
    let task: CRMTask

    private var companyName: String {
        guard let cid = task.clientID else { return "" }
        return store.clients.first(where: { $0.id == cid })?.name ?? ""
    }

    var body: some View {
        HStack(spacing: 12) {
            // Priority icon
            Image(systemName: task.priority.icon)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(task.priority.color)
                .frame(width: 22)

            // Main content
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if !companyName.isEmpty {
                        Label(companyName, systemImage: "building.2")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    if let due = task.dueDate {
                        if !companyName.isEmpty {
                            Text("·").font(.caption).foregroundColor(.secondary)
                        }
                        Label(shortDate(due), systemImage: "calendar")
                            .font(.caption)
                            .foregroundColor(task.isOverdue ? .red : .secondary)
                    }
                }
            }

            Spacer(minLength: 4)

            // Status badge
            Text(task.effectiveStatusLabel)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(task.effectiveStatusColor.opacity(0.15))
                .foregroundColor(task.effectiveStatusColor)
                .clipShape(Capsule())

            // Checkmark button
            if store.currentUserRole.canEditCRM {
                Button {
                    var updated = task
                    updated.status = .done
                    updated.completedAt = Date()
                    store.upsertCRMTask(updated)
                } label: {
                    Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundColor(task.status == .done ? .green : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Empty State

private struct TaskEmptyState: View {
    let icon: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 52))
                .foregroundColor(.secondary.opacity(0.5))
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }
}

// MARK: - CRMTaskFullDetailView

struct CRMTaskFullDetailView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let task: CRMTask

    @State private var isEditing: Bool = false
    @State private var showDeleteConfirm: Bool = false

    // Edit fields
    @State private var editTitle: String = ""
    @State private var editDescription: String = ""
    @State private var editPriority: CRMTaskPriority = .normal
    @State private var editStatus: CRMTaskStatus = .open
    @State private var editAssignedToName: String = ""
    @State private var editIncludeDueDate: Bool = false
    @State private var editDueDate: Date = Date()

    private var linkedCompanyName: String {
        guard let cid = task.clientID else { return "" }
        return store.clients.first(where: { $0.id == cid })?.name ?? ""
    }

    private var linkedOpportunityTitle: String {
        guard let oid = task.opportunityID else { return "" }
        return store.crmOpportunities.first(where: { $0.id == oid })?.title ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if isEditing {
                    editingContent
                } else {
                    readingContent
                }
            }
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(isEditing ? "Edit Task" : "Task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isEditing {
                    Button("Save") { saveTask() }
                        .fontWeight(.semibold)
                        .disabled(editTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                } else if store.currentUserRole.canEditCRM {
                    Button("Edit") { beginEditing() }
                }
            }
            if isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isEditing = false }
                }
            }
        }
        .confirmationDialog("Delete Task", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.deleteCRMTask(task)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .onAppear { seedEditFields() }
    }

    // MARK: Reading mode

    private var readingContent: some View {
        VStack(spacing: 16) {
            // Header card
            VStack(alignment: .leading, spacing: 10) {
                Text(task.title)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.primary)

                HStack(spacing: 8) {
                    TaskPriorityBadge(priority: task.priority)
                    TaskStatusBadge(label: task.effectiveStatusLabel, color: task.effectiveStatusColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.top, 16)

            // Details card
            VStack(spacing: 0) {
                if !task.description_.isEmpty {
                    TaskDetailRow(icon: "text.alignleft", label: "Description", value: task.description_)
                    Divider().padding(.leading, 44)
                }
                TaskDetailRow(icon: "calendar", label: "Due Date",
                              value: task.dueDate.map { shortDateFormatter.string(from: $0) } ?? "No due date")
                if !task.assignedToName.isEmpty {
                    Divider().padding(.leading, 44)
                    TaskDetailRow(icon: "person.fill", label: "Assigned To", value: task.assignedToName)
                }
                if !linkedCompanyName.isEmpty {
                    Divider().padding(.leading, 44)
                    TaskDetailRow(icon: "building.2.fill", label: "Company", value: linkedCompanyName)
                }
                if !linkedOpportunityTitle.isEmpty {
                    Divider().padding(.leading, 44)
                    TaskDetailRow(icon: "chart.bar.fill", label: "Opportunity", value: linkedOpportunityTitle)
                }
                if let completedAt = task.completedAt {
                    Divider().padding(.leading, 44)
                    TaskDetailRow(icon: "checkmark.seal.fill", label: "Completed",
                                  value: shortDateFormatter.string(from: completedAt))
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)

            // Mark Done button
            if task.status != .done && store.currentUserRole.canEditCRM {
                Button {
                    var updated = task
                    updated.status = .done
                    updated.completedAt = Date()
                    store.upsertCRMTask(updated)
                    dismiss()
                } label: {
                    Label("Mark Done", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.green)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 16)
            } else if task.status == .done {
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                    Text("Completed").font(.subheadline.weight(.semibold)).foregroundColor(.green)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.green.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
            }

            // Delete button
            if store.currentUserRole.canDeleteCRMTasks {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete Task", systemImage: "trash")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.red.opacity(0.1))
                        .foregroundColor(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: Editing mode

    private var editingContent: some View {
        VStack(spacing: 16) {
            // Title & Description
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Title").font(.caption).foregroundColor(.secondary)
                    TextField("Task title", text: $editTitle)
                        .font(.subheadline)
                }
                .padding(14)

                Divider().padding(.leading, 14)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Description").font(.caption).foregroundColor(.secondary)
                    TextEditor(text: $editDescription)
                        .font(.subheadline)
                        .frame(minHeight: 72)
                }
                .padding(14)
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.top, 16)

            // Priority & Status
            VStack(spacing: 0) {
                HStack {
                    Text("Priority").font(.subheadline).foregroundColor(.primary)
                    Spacer()
                    Picker("Priority", selection: $editPriority) {
                        ForEach(CRMTaskPriority.allCases, id: \.self) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                    .pickerStyle(.menu)
                }
                .padding(14)

                Divider().padding(.leading, 14)

                HStack {
                    Text("Status").font(.subheadline).foregroundColor(.primary)
                    Spacer()
                    Picker("Status", selection: $editStatus) {
                        ForEach(CRMTaskStatus.allCases, id: \.self) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                    .pickerStyle(.menu)
                }
                .padding(14)
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)

            // Due Date
            VStack(spacing: 0) {
                Toggle("Due Date", isOn: $editIncludeDueDate)
                    .padding(14)

                if editIncludeDueDate {
                    Divider().padding(.leading, 14)
                    DatePicker("", selection: $editDueDate, displayedComponents: [.date])
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .padding(14)
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)

            // Assigned To
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Assigned To").font(.caption).foregroundColor(.secondary)
                    TextField("Name", text: $editAssignedToName)
                        .font(.subheadline)
                }
                .padding(14)
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)

            // Linked info (read-only in edit mode)
            if !linkedCompanyName.isEmpty || !linkedOpportunityTitle.isEmpty {
                VStack(spacing: 0) {
                    if !linkedCompanyName.isEmpty {
                        TaskDetailRow(icon: "building.2.fill", label: "Company", value: linkedCompanyName)
                    }
                    if !linkedOpportunityTitle.isEmpty {
                        if !linkedCompanyName.isEmpty { Divider().padding(.leading, 44) }
                        TaskDetailRow(icon: "chart.bar.fill", label: "Opportunity", value: linkedOpportunityTitle)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: Helpers

    private func seedEditFields() {
        editTitle         = task.title
        editDescription   = task.description_
        editPriority      = task.priority
        editStatus        = task.status
        editAssignedToName = task.assignedToName
        editIncludeDueDate = task.dueDate != nil
        editDueDate       = task.dueDate ?? Date()
    }

    private func beginEditing() {
        seedEditFields()
        isEditing = true
    }

    private func saveTask() {
        var updated         = task
        updated.title       = editTitle.trimmingCharacters(in: .whitespaces)
        updated.description_ = editDescription
        updated.priority    = editPriority
        updated.status      = editStatus
        updated.assignedToName = editAssignedToName
        updated.dueDate     = editIncludeDueDate ? editDueDate : nil
        if editStatus == .done && task.status != .done {
            updated.completedAt = Date()
        }
        store.upsertCRMTask(updated)
        isEditing = false
    }
}

// MARK: - Shared Sub-views

private struct TaskPriorityBadge: View {
    let priority: CRMTaskPriority
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: priority.icon).font(.caption2.weight(.semibold))
            Text(priority.rawValue).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(priority.color.opacity(0.15))
        .foregroundColor(priority.color)
        .clipShape(Capsule())
    }
}

private struct TaskStatusBadge: View {
    let label: String
    let color: Color
    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}

private struct TaskDetailRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundColor(.secondary)
                Text(value).font(.subheadline).foregroundColor(.primary)
            }
            Spacer()
        }
        .padding(14)
    }
}

// MARK: - Priority sort order helper

private extension CRMTaskPriority {
    var sortOrder: Int {
        switch self {
        case .low:    return 0
        case .normal: return 1
        case .high:   return 2
        case .urgent: return 3
        }
    }
}
