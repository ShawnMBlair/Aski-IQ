// CRMHubView.swift
// BV APP – CRM Tab Hub + Supporting Sheets

import SwiftUI
import Foundation

// MARK: - CRM Hub (Root Tab View)

struct CRMHubView: View {
    @EnvironmentObject var store: AppStore
    @State private var showSearch = false
    @AppStorage("crmHubSelectedTab") private var selectedTab: Int = 0

    private let tabs: [(label: String, icon: String)] = [
        ("Dashboard", "house.fill"),
        ("Companies", "building.2.fill"),
        ("Pipeline",  "chart.bar.fill"),
        ("Tasks",     "checklist"),
        ("Contracts", "doc.text.fill"),
        ("Reports",   "chart.bar.xaxis"),
        ("AI",        "sparkles")
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Custom top tab strip
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(tabs.indices, id: \.self) { i in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { selectedTab = i }
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: tabs[i].icon)
                                        .font(.system(size: 16, weight: .semibold))
                                    Text(tabs[i].label)
                                        .font(.caption.weight(.semibold))
                                }
                                .foregroundColor(selectedTab == i ? .accentColor : .secondary)
                                .padding(.vertical, 10)
                                .padding(.horizontal, 20)
                                .overlay(
                                    Rectangle()
                                        .frame(height: 2)
                                        .foregroundColor(selectedTab == i ? .accentColor : .clear),
                                    alignment: .bottom
                                )
                            }
                        }
                    }
                }
                .background(Color(.systemBackground))

                Divider()

                // Content
                crmContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("CRM")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showSearch = true } label: {
                        Image(systemName: "magnifyingglass")
                    }
                }
            }
            .sheet(isPresented: $showSearch) {
                CRMSearchView().environmentObject(store)
            }
        }
    }

    @ViewBuilder
    private var crmContent: some View {
        switch selectedTab {
        case 0:
            ScrollView {
                CRMDashboardInlineView()
                    .environmentObject(store)
            }
            .background(Color(.systemGroupedBackground))
            // Pull-to-refresh on the embedded CRM tab — re-runs sync +
            // outcome-timestamp backfill so the cards reflect fresh data.
            .refreshable {
                await store.refreshAll()
            }
        case 1: CRMCompanyListView().environmentObject(store)
        case 2: CRMPipelineView().environmentObject(store)
        case 3: CRMTaskListView().environmentObject(store)
        case 4: ContractListView().environmentObject(store)
        case 5: CRMReportsView().environmentObject(store)
        case 6:
            ScrollView {
                CRMAIHubView()
                    .environmentObject(store)
                    .padding()
            }
            .background(Color(.systemGroupedBackground))
        default: EmptyView()
        }
    }
}

// MARK: - Placeholder Views

// CRMPipelineView is defined in CRMOpportunityViews.swift
// CRMTaskListView is defined in CRMTaskViews.swift

// MARK: - CRM Task Detail Sheet

struct CRMTaskDetailSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let task: CRMTask

    private var formattedDueDate: String {
        guard let date = task.dueDate else { return "No due date" }
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f.string(from: date)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // Title & Priority Badge
                    VStack(alignment: .leading, spacing: 8) {
                        Text(task.title)
                            .font(.title3.weight(.semibold))
                            .foregroundColor(.primary)

                        HStack(spacing: 8) {
                            PriorityBadge(priority: task.priority)
                            CRMTaskStatusBadge(status: task.status, isOverdue: task.isOverdue)
                        }
                    }
                    .padding(.horizontal, 20)

                    Divider()

                    // Details
                    VStack(alignment: .leading, spacing: 14) {
                        if !task.description_.isEmpty {
                            DetailRow(icon: "text.alignleft", label: "Description", value: task.description_)
                        }
                        DetailRow(icon: "calendar", label: "Due Date", value: formattedDueDate)
                        if !task.assignedToName.isEmpty {
                            DetailRow(icon: "person.fill", label: "Assigned To", value: task.assignedToName)
                        }
                    }
                    .padding(.horizontal, 20)

                    Spacer(minLength: 20)

                    // Mark Done Button
                    if task.status != .done {
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
                                .cornerRadius(12)
                        }
                        .padding(.horizontal, 20)
                    } else {
                        HStack {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(.green)
                            Text("Task Completed")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.green)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.green.opacity(0.12))
                        .cornerRadius(12)
                        .padding(.horizontal, 20)
                    }

                    Spacer(minLength: 24)
                }
                .padding(.top, 16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Task Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: Task Detail Sub-views

private struct PriorityBadge: View {
    let priority: CRMTaskPriority

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: priority.icon)
                .font(.caption2.weight(.semibold))
            Text(priority.rawValue)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(priority.color.opacity(0.15))
        .foregroundColor(priority.color)
        .cornerRadius(8)
    }
}

private struct CRMTaskStatusBadge: View {
    let status: CRMTaskStatus
    let isOverdue: Bool

    private var label: String {
        if isOverdue { return "Overdue" }
        return status.rawValue
    }
    private var color: Color {
        if isOverdue { return .red }
        switch status {
        case .open:       return .blue
        case .inProgress: return .orange
        case .done:       return .green
        }
    }

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(8)
    }
}

private struct DetailRow: View {
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
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.subheadline)
                    .foregroundColor(.primary)
            }

            Spacer()
        }
    }
}

// MARK: - CRM Task Create Sheet

struct CRMTaskCreateSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let clientID: UUID?
    let opportunityID: UUID?

    @State private var title: String = ""
    @State private var dueDate: Date = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var priority: CRMTaskPriority = .normal
    @State private var includeDueDate: Bool = true
    @State private var showValidationError: Bool = false

    private var minDueDate: Date { Calendar.current.startOfDay(for: Date()) }

    private var isSaveDisabled: Bool { title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task Details") {
                    TextField("Title", text: $title)
                        .textInputAutocapitalization(.sentences)

                    Toggle("Set Due Date", isOn: $includeDueDate)

                    if includeDueDate {
                        DatePicker(
                            "Due Date",
                            selection: $dueDate,
                            in: minDueDate...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                }

                Section("Priority") {
                    Picker("Priority", selection: $priority) {
                        ForEach(CRMTaskPriority.allCases, id: \.self) { p in
                            Label(p.rawValue, systemImage: p.icon)
                                .foregroundColor(p.color)
                                .tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if clientID != nil || opportunityID != nil {
                    Section("Linked To") {
                        if let cid = clientID,
                           let client = store.clients.first(where: { $0.id == cid }) {
                            HStack {
                                Image(systemName: "building.2.fill")
                                    .foregroundColor(.secondary)
                                Text(client.name)
                                    .foregroundColor(.secondary)
                            }
                        }
                        if opportunityID != nil {
                            HStack {
                                Image(systemName: "chart.bar.fill")
                                    .foregroundColor(.secondary)
                                Text("Linked to opportunity")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                if showValidationError {
                    Section {
                        Text("Please enter a task title.")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveTask() }
                        .disabled(isSaveDisabled)
                }
            }
        }
    }

    private func saveTask() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            showValidationError = true
            return
        }
        var task = CRMTask()
        task.title = trimmed
        task.dueDate = includeDueDate ? dueDate : nil
        task.priority = priority
        task.status = .open
        task.clientID = clientID
        task.opportunityID = opportunityID
        task.assignedToID = store.currentUser?.id
        task.assignedToName = store.currentUser?.fullName ?? ""
        store.upsertCRMTask(task)
        dismiss()
    }
}
