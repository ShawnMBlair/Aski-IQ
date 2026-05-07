// CostCodePickerSheet.swift
// Aski IQ – Cost Code Picker (search + grouped + recent)

import SwiftUI

// MARK: - Recent Cost Codes (persisted per device)

private enum RecentCostCodes {
    private static let key = "aski_recent_cost_codes"
    private static let max = 5

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func record(_ code: String) {
        var recent = load().filter { $0 != code }
        recent.insert(code, at: 0)
        UserDefaults.standard.set(Array(recent.prefix(max)), forKey: key)
    }
}

// MARK: - Picker Sheet

struct CostCodePickerSheet: View {
    @EnvironmentObject var store: AppStore
    let projectID: UUID?
    let onSelect: (CompanyCostCode) -> Void

    @State private var search = ""
    @State private var recentCodes: [String] = []
    @Environment(\.dismiss) private var dismiss

    private var allCodes: [CompanyCostCode] {
        store.costCodes(forProjectID: projectID)
    }

    private var isProjectMode: Bool {
        if let id = projectID,
           let budget = store.projectBudgets.first(where: { $0.projectID == id }) {
            return !budget.lines.isEmpty
        }
        return false
    }

    private var filtered: [CompanyCostCode] {
        guard !search.isEmpty else { return allCodes }
        let q = search.lowercased()
        return allCodes.filter {
            $0.code.lowercased().contains(q) ||
            $0.description.lowercased().contains(q) ||
            $0.category.rawValue.lowercased().contains(q)
        }
    }

    private var recentItems: [CompanyCostCode] {
        recentCodes.compactMap { code in
            allCodes.first { $0.code == code }
        }
    }

    private var groupedFiltered: [(CostCodeCategory, [CompanyCostCode])] {
        if isProjectMode {
            // Project mode: flat list, no grouping needed
            return []
        }
        let grouped = Dictionary(grouping: filtered, by: \.category)
        return CostCodeCategory.allCases.compactMap { cat in
            guard let codes = grouped[cat], !codes.isEmpty else { return nil }
            return (cat, codes.sorted { $0.sortOrder < $1.sortOrder })
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Recent section
                if search.isEmpty && !recentItems.isEmpty {
                    Section {
                        ForEach(recentItems) { item in
                            CodeRow(item: item) { select(item) }
                        }
                    } header: {
                        Label("Recent", systemImage: "clock")
                    }
                }

                if isProjectMode {
                    // Project budget codes — flat list
                    Section {
                        ForEach(filtered) { item in
                            CodeRow(item: item) { select(item) }
                        }
                    } header: {
                        Label("Project Cost Codes", systemImage: "folder.fill")
                    }
                } else {
                    // Company codes — grouped by category
                    ForEach(groupedFiltered, id: \.0) { category, codes in
                        Section {
                            ForEach(codes) { item in
                                CodeRow(item: item) { select(item) }
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: category.icon)
                                    .foregroundColor(category.color)
                                Text(category.rawValue)
                            }
                        }
                    }
                }

                if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: "Search cost codes…")
            .navigationTitle("Cost Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { recentCodes = RecentCostCodes.load() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func select(_ item: CompanyCostCode) {
        RecentCostCodes.record(item.code)
        onSelect(item)
        dismiss()
    }
}

// MARK: - Code Row

private struct CodeRow: View {
    let item: CompanyCostCode
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.code)
                        .font(.system(.subheadline, design: .monospaced))
                        .bold()
                        .foregroundColor(.primary)
                    Text(item.description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
