// PaginatedList.swift
// BV APP – Generic pagination helper (Sprint 12)

import SwiftUI
import Combine

// MARK: - Paginated List Helper

/// Wraps any RandomAccessCollection and exposes a window of `pageSize` items.
/// Call `loadMore()` to expand the window. Resets automatically when `items` changes.
@MainActor
final class PaginationState: ObservableObject {
    let pageSize: Int
    @Published private(set) var displayLimit: Int

    init(pageSize: Int = 20) {
        self.pageSize    = pageSize
        self.displayLimit = pageSize
    }

    func loadMore() {
        displayLimit += pageSize
    }

    func reset() {
        displayLimit = pageSize
    }
}

// MARK: - Load More Footer

/// Drop this at the bottom of any List/ForEach to get a "Load More" row.
struct LoadMoreFooter: View {
    let showing:  Int
    let total:    Int
    let onLoad:   () -> Void

    private var remaining: Int { total - showing }

    var body: some View {
        if showing < total {
            HStack {
                Spacer()
                Button {
                    onLoad()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "ellipsis.circle")
                        Text("Load \(min(remaining, 20)) more  (\(remaining) remaining)")
                            .font(.subheadline)
                    }
                    .foregroundColor(.blue)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .listRowSeparator(.hidden)
        }
    }
}
