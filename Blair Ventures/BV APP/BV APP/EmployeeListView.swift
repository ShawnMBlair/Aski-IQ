// EmployeeListView.swift
// FieldOS – Employee List

import SwiftUI

struct EmployeeListView: View {
    @EnvironmentObject var store: AppStore
    @State private var searchText = ""
    @State private var selectedRole: UserRole? = nil
    @State private var showCreateEmployee = false
    @StateObject private var pagination = PaginationState(pageSize: 20)

    private var filtered: [Employee] {
        store.employees
            .filter { $0.isActive }
            .filter { selectedRole == nil || $0.role == selectedRole }
            .filter {
                searchText.isEmpty ||
                $0.fullName.localizedCaseInsensitiveContains(searchText) ||
                ($0.trade ?? "").localizedCaseInsensitiveContains(searchText)
            }
            .sorted { $0.lastName < $1.lastName }
    }

    private var visible: [Employee] {
        Array(filtered.prefix(pagination.displayLimit))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // MARK: - Role Filter
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(label: "All", isSelected: selectedRole == nil) {
                            selectedRole = nil
                        }
                        ForEach(UserRole.allCases, id: \.self) { role in
                            FilterChip(label: role.rawValue.capitalized, isSelected: selectedRole == role) {
                                selectedRole = selectedRole == role ? nil : role
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }

                Divider()

                if filtered.isEmpty {
                    // Distinguish "tenant has no employees yet" (true empty —
                    // show guidance + Add button) from "filter excluded
                    // everyone" (data exists, just filtered out — short caption).
                    if store.employees.isEmpty {
                        Spacer()
                        EmptyStatePlaceholder(
                            icon: "person.2.fill",
                            title: "No employees yet",
                            subtitle: "Add your team members to assign them to projects, log hours, and track certifications.",
                            actionTitle: "Add Employee",
                            action: { showCreateEmployee = true }
                        )
                        Spacer()
                    } else {
                        Spacer()
                        EmptyCard(message: "No employees match this filter.")
                        Spacer()
                    }
                } else {
                    List {
                        ForEach(visible) { employee in
                            NavigationLink {
                                EmployeeDetailView(employee: employee)
                            } label: {
                                EmployeeListRow(employee: employee)
                            }
                        }
                        LoadMoreFooter(
                            showing: visible.count,
                            total:   filtered.count,
                            onLoad:  { pagination.loadMore() }
                        )
                    }
                    .listStyle(.plain)
                    .onChange(of: searchText)    { _ in pagination.reset() }
                    .onChange(of: selectedRole)  { _ in pagination.reset() }
                }
            }
            .searchable(text: $searchText, prompt: "Search name or trade")
            .refreshable { await store.refreshAll() }
            .navigationTitle("Employees")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showCreateEmployee = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add employee")
                }
            }
            .sheet(isPresented: $showCreateEmployee) {
                EmployeeCreateEditView()
            }
        }
    }
}

// MARK: - Employee List Row

struct EmployeeListRow: View {
    let employee: Employee

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            Circle()
                .fill(Color.blue.opacity(0.15))
                .frame(width: 44, height: 44)
                .overlay(
                    Text(employee.initials)
                        .font(.headline)
                        .foregroundColor(.blue)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(employee.fullName).font(.headline)
                HStack(spacing: 8) {
                    Text(employee.role.rawValue.capitalized)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.systemGray5))
                        .cornerRadius(4)
                    if let trade = employee.trade {
                        Text(trade)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

extension Employee {
    var initials: String {
        let f = firstName.prefix(1).uppercased()
        let l = lastName.prefix(1).uppercased()
        return "\(f)\(l)"
    }
}
