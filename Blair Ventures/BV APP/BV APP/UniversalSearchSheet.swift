// UniversalSearchSheet.swift
// Aski IQ — Cross-entity search sheet.
//
// USAGE
//   .sheet(isPresented: $showSearch) {
//       UniversalSearchSheet().environmentObject(store)
//   }
//
// Tapping a result publishes an open-record intent on AppStore so the active
// scene can navigate. RootView already has a deep-link handler pattern; this
// piggybacks on it via a new `pendingOpenRecord` published property.

import SwiftUI

struct UniversalSearchSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    @State private var query: String = ""
    @State private var debounced: String = ""
    @State private var selectedKinds: Set<UniversalSearchResult.Kind> = []
    @State private var debounceTask: Task<Void, Never>? = nil

    private var allowedKinds: Set<UniversalSearchResult.Kind>? {
        selectedKinds.isEmpty ? nil : selectedKinds
    }

    private var results: [UniversalSearchResult] {
        guard !debounced.isEmpty else { return [] }
        return UniversalSearchService.shared.search(debounced, in: store, kinds: allowedKinds)
    }

    private var grouped: [(UniversalSearchResult.Kind, [UniversalSearchResult])] {
        UniversalSearchService.shared.grouped(results)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                filterChips
                Divider()
                content
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // iPad / iPhone Plus: allow the user to keep the underlying screen
        // partially visible while glancing at search hits.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Subviews

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Clients, projects, quotes, contacts…", text: $query)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .submitLabel(.search)
                .onSubmit { recordRecent() }
                .accessibilityLabel("Universal search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.top, 8)
        .onChange(of: query) { _, new in scheduleDebounce(new) }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(label: "All", isSelected: selectedKinds.isEmpty) {
                    selectedKinds.removeAll()
                }
                ForEach(UniversalSearchResult.Kind.allCases, id: \.rawValue) { kind in
                    FilterChip(label: kind.rawValue, isSelected: selectedKinds.contains(kind)) {
                        if selectedKinds.contains(kind) {
                            selectedKinds.remove(kind)
                        } else {
                            selectedKinds.insert(kind)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var content: some View {
        if debounced.isEmpty {
            recentsView
        } else if grouped.isEmpty {
            emptyView
        } else {
            resultsList
        }
    }

    private var recentsView: some View {
        let recents = UniversalSearchService.shared.recents
        return Group {
            if recents.isEmpty {
                emptyHint(
                    icon: "magnifyingglass",
                    title: "Start typing",
                    body: "Search across clients, projects, quotes, contacts, opportunities, invoices, employees, forms, and incidents."
                )
            } else {
                List {
                    Section {
                        ForEach(recents, id: \.self) { term in
                            Button {
                                query = term
                                debounced = term
                            } label: {
                                HStack {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .foregroundColor(.secondary)
                                    Text(term).foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "arrow.up.left")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Recent searches")
                            Spacer()
                            Button("Clear") {
                                UniversalSearchService.shared.clearRecents()
                                // Force re-render
                                debounced = " "
                                debounced = ""
                            }
                            .font(.caption)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private var emptyView: some View {
        emptyHint(
            icon: "magnifyingglass",
            title: "Nothing found",
            body: "No matches for \"\(debounced)\". Try a shorter search or pick a different filter."
        )
    }

    @ViewBuilder
    private func emptyHint(icon: String, title: String, body: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text(title).font(.headline)
            Text(body)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsList: some View {
        List {
            ForEach(grouped, id: \.0) { kind, items in
                Section {
                    ForEach(items) { result in
                        Button {
                            handleTap(result)
                        } label: {
                            row(result)
                        }
                    }
                } header: {
                    HStack {
                        Image(systemName: kind.icon)
                            .foregroundColor(.secondary)
                        Text(kind.rawValue)
                        Spacer()
                        Text("\(items.count)").foregroundColor(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func row(_ r: UniversalSearchResult) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: r.kind.icon)
                .foregroundColor(color(for: r.kind))
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title)
                    .font(.subheadline).bold()
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(r.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if let snippet = r.snippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func color(for kind: UniversalSearchResult.Kind) -> Color {
        switch kind.color {
        case "blue":   return .blue
        case "indigo": return .indigo
        case "teal":   return .teal
        case "purple": return .purple
        case "green":  return .green
        case "orange": return .orange
        case "pink":   return .pink
        case "yellow": return .yellow
        case "red":    return .red
        default:       return .secondary
        }
    }

    // MARK: - Behavior

    private func scheduleDebounce(_ new: String) {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)  // 250ms
            if !Task.isCancelled {
                await MainActor.run { debounced = new }
            }
        }
    }

    private func recordRecent() {
        UniversalSearchService.shared.recordRecent(query)
    }

    /// On tap: record the search and publish an open-record intent on the
    /// store. RootView observes this and routes to the appropriate detail view.
    /// Falls back to closing the sheet so the user lands somewhere if the
    /// intent isn't handled.
    private func handleTap(_ r: UniversalSearchResult) {
        recordRecent()
        store.pendingOpenRecord = OpenRecordIntent(kind: r.kind, recordID: r.id)
        dismiss()
    }
}

// MARK: - Open-record intent

/// Set on AppStore when the user taps a search result. RootView observes and
/// routes. Cleared after handling.
struct OpenRecordIntent: Equatable {
    let kind: UniversalSearchResult.Kind
    let recordID: UUID
}
