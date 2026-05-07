// CrewListView.swift
// FieldOS – Crew List

import SwiftUI

struct CrewListView: View {
    @EnvironmentObject var store: AppStore
    @State private var searchText = ""
    @State private var showCreateCrew = false
    @StateObject private var pagination = PaginationState(pageSize: 20)

    private var filtered: [Crew] {
        store.crews
            .filter { $0.isActive }
            .filter {
                searchText.isEmpty ||
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
            .sorted { $0.name < $1.name }
    }

    private var visible: [Crew] { Array(filtered.prefix(pagination.displayLimit)) }

    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty {
                    VStack {
                        Spacer()
                        EmptyCard(message: "No crews yet. Tap + to create one.")
                        Spacer()
                    }
                } else {
                    List {
                        ForEach(visible) { crew in
                            NavigationLink {
                                CrewDetailView(crew: crew)
                            } label: {
                                CrewListRow(crew: crew)
                            }
                        }
                        LoadMoreFooter(
                            showing: visible.count,
                            total:   filtered.count,
                            onLoad:  { pagination.loadMore() }
                        )
                    }
                    .listStyle(.plain)
                    .onChange(of: searchText) { pagination.reset() }
                }
            }
            .searchable(text: $searchText, prompt: "Search crews")
            .refreshable { await store.refreshAll() }
            .navigationTitle("Crews")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showCreateCrew = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add crew")
                }
            }
            .sheet(isPresented: $showCreateCrew) {
                CrewCreateEditView()
            }
        }
    }
}

// MARK: - Crew List Row

struct CrewListRow: View {
    let crew: Crew
    @EnvironmentObject var store: AppStore

    private var foremanName: String {
        crew.foremanID.flatMap { store.employee(id: $0) }?.fullName ?? "No foreman"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(crew.name).font(.headline)
            HStack(spacing: 16) {
                Label(foremanName, systemImage: "person.fill")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Label("\(crew.memberIDs.count) members", systemImage: "person.3")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
