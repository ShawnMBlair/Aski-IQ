// ProjectListView.swift
// FieldOS – Projects Module

import SwiftUI

private enum ProjectCreateFlow: Identifiable {
    case pickParent
    case create(UUID)
    var id: String {
        switch self {
        case .pickParent:        return "pickParent"
        case .create(let oppID): return "create-\(oppID.uuidString)"
        }
    }
}

struct ProjectListView: View {
    @EnvironmentObject var store: AppStore
    @State private var searchText = ""
    @State private var selectedFilter: ProjectStatus? = nil
    @State private var flow: ProjectCreateFlow? = nil
    @StateObject private var pagination = PaginationState(pageSize: 20)

    private var filteredProjects: [Project] {
        store.projects
            .filter { selectedFilter == nil || $0.status == selectedFilter }
            .filter {
                searchText.isEmpty ||
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.clientName.localizedCaseInsensitiveContains(searchText)
            }
            .sorted { $0.name < $1.name }
    }

    private var visibleProjects: [Project] {
        Array(filteredProjects.prefix(pagination.displayLimit))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // MARK: - Filter Bar
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(label: "All", isSelected: selectedFilter == nil) {
                            selectedFilter = nil
                        }
                        ForEach(ProjectStatus.allCases, id: \.self) { status in
                            FilterChip(
                                label: status.displayName,
                                isSelected: selectedFilter == status
                            ) {
                                selectedFilter = selectedFilter == status ? nil : status
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }
                .background(Color(.systemBackground))

                Divider()

                // MARK: - Project List
                if filteredProjects.isEmpty {
                    Spacer()
                    EmptyCard(message: selectedFilter != nil
                        ? "No \(selectedFilter!.displayName.lowercased()) projects."
                        : "No projects yet. Tap + to create one.")
                    Spacer()
                } else {
                    List {
                        ForEach(visibleProjects) { project in
                            NavigationLink {
                                ProjectDetailView(project: project)
                            } label: {
                                ProjectListRow(project: project)
                            }
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }
                        LoadMoreFooter(
                            showing: visibleProjects.count,
                            total:   filteredProjects.count,
                            onLoad:  { pagination.loadMore() }
                        )
                    }
                    .listStyle(.plain)
                    .onChange(of: searchText)    { _ in pagination.reset() }
                    .onChange(of: selectedFilter) { pagination.reset() }
                }
            }
            .searchable(text: $searchText, prompt: "Search projects or clients")
            .refreshable { await store.refreshAll() }
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        flow = .pickParent
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add project")
                    .accessibilityHint("Opens the opportunity picker before the new project form")
                }
            }
            // Phase 7 / Decision 1: route Project create through an
            // Opportunity picker. Per the entity-first pattern, every
            // project should originate from a CRM opportunity. Pre-fix
            // the `+` opened ProjectCreateEditView with no
            // opportunity_id; even though the schema lets that pass
            // (nullable on iOS, NOT NULL on prod via a later auto-link
            // trigger), the trigger fallback is for legacy data and
            // shouldn't be the normal happy path.
            .sheet(item: $flow) { state in
                switch state {
                case .pickParent:
                    RequiredOpportunityPickerSheet { picked in
                        flow = .create(picked)
                    }
                    .environmentObject(store)
                case .create(let oppID):
                    ProjectCreateEditView(preselectedOpportunityID: oppID)
                        .environmentObject(store)
                }
            }
        }
    }
}

// MARK: - Project List Row

struct ProjectListRow: View {
    let project: Project
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(project.name)
                    .font(.headline)
                Spacer()
                StatusBadge(status: project.status)
            }
            Text(project.clientName)
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack(spacing: 16) {
                if !store.currentUserRole.isFieldRole,
                   let value = project.contractValue {
                    Label(value.currencyString, systemImage: "dollarsign.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let start = project.startDate {
                    Label(start.shortDate, systemImage: "calendar")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline)
                .bold(isSelected)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? Color.blue : Color(.systemGray5))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(20)
        }
    }
}

// MARK: - Extensions

extension ProjectStatus {
    var displayName: String {
        switch self {
        case .tendering: return "Tendering"
        case .awarded: return "Awarded"
        case .active: return "Active"
        case .onHold: return "On Hold"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        }
    }
}

extension Decimal {
    var currencyString: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 0
        return formatter.string(from: self as NSDecimalNumber) ?? "$\(self)"
    }
}

extension Date {
    var shortDate: String {
        formatted(date: .abbreviated, time: .omitted)
    }
}
