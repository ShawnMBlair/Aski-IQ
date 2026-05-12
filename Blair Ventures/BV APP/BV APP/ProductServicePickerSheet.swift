// ProductServicePickerSheet.swift
// Aski IQ – Product/Service Picker for Quote Line Items
// Replaces manual AddLineItemSheet with library-backed two-step flow.

import SwiftUI

struct ProductServicePickerSheet: View {
    let clientID: UUID?
    let onAdd: (CostCodeItem) -> Void

    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    // Step 1 state
    @State private var searchText  = ""
    @State private var typeFilter: ProductServiceType? = nil

    // Step 2 state
    @State private var selectedItem: ProductService? = nil
    @State private var quantityString    = ""
    @State private var useCustomPrice    = false
    @State private var customPriceString = ""
    @State private var itemNotes         = ""

    // ── Body ──────────────────────────────────────────────────────────────────

    var body: some View {
        NavigationStack {
            if let selected = selectedItem {
                confirmView(for: selected)
            } else {
                browseView
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Step 1 — Browse & Select

    private var browseView: some View {
        let filtered = filteredItems
        return List {
            // Type filter chips
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        PSFilterChip(label: "All", isSelected: typeFilter == nil) {
                            typeFilter = nil
                        }
                        ForEach(ProductServiceType.allCases) { t in
                            PSFilterChip(
                                label: t.displayName,
                                icon: t.icon,
                                color: t.color,
                                isSelected: typeFilter == t
                            ) {
                                typeFilter = (typeFilter == t) ? nil : t
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            .listRowBackground(Color.clear)

            // Empty states
            if filtered.isEmpty {
                if store.activeProductServices.isEmpty {
                    ContentUnavailableView(
                        "No Products or Services",
                        systemImage: "shippingbox",
                        description: Text("Go to Settings → Products & Services to build your library.")
                    )
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            } else {
                ForEach(filtered) { item in
                    let resolved = store.resolvedPrice(for: item, clientID: clientID)
                    let isClientPrice = resolved != item.defaultPrice
                    Button {
                        selectedItem      = item
                        customPriceString = NSDecimalNumber(decimal: resolved).stringValue
                        quantityString    = ""
                        useCustomPrice    = false
                        itemNotes         = ""
                    } label: {
                        HStack {
                            PSLibraryRow(item: item, clientPrice: isClientPrice ? resolved : nil)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "Search products & services…")
        .navigationTitle("Add Line Item")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private var filteredItems: [ProductService] {
        store.activeProductServices.filter { item in
            (typeFilter == nil || item.type == typeFilter) &&
            (searchText.isEmpty ||
                item.name.localizedCaseInsensitiveContains(searchText) ||
                item.costCode.localizedCaseInsensitiveContains(searchText) ||
                item.description.localizedCaseInsensitiveContains(searchText) ||
                item.category.rawValue.localizedCaseInsensitiveContains(searchText))
        }
    }

    // MARK: Step 2 — Quantity & Confirm

    @ViewBuilder
    private func confirmView(for item: ProductService) -> some View {
        let resolvedPrice = store.resolvedPrice(for: item, clientID: clientID)
        let isClientPrice = resolvedPrice != item.defaultPrice
        let effectivePrice: Decimal = useCustomPrice
            ? (Decimal(string: customPriceString) ?? resolvedPrice)
            : resolvedPrice
        let qty: Decimal = Decimal(string: quantityString) ?? 0
        let lineTotal = qty * effectivePrice
        let canAdd    = qty > 0

        Form {
            // ── Item summary (read-only) ───────────────────────────────────
            Section {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(item.type.color.opacity(0.12))
                            .frame(width: 44, height: 44)
                        Image(systemName: item.type.icon)
                            .foregroundColor(item.type.color)
                            .font(.system(size: 18))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name)
                            .font(.headline)
                        HStack(spacing: 6) {
                            Text(item.costCode)
                                .font(.caption).foregroundColor(.secondary)
                                .fontDesign(.monospaced)
                            Text("·").foregroundColor(.secondary).font(.caption)
                            Text(item.category.rawValue)
                                .font(.caption)
                                .foregroundColor(item.category.color)
                        }
                        if !item.description.isEmpty {
                            Text(item.description)
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // ── Unit Price ────────────────────────────────────────────────
            Section("Pricing") {
                HStack {
                    Text("Unit Price")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(resolvedPrice.currencyString) / \(item.unit)")
                            .font(.subheadline).bold()
                            .foregroundColor(isClientPrice ? .green : .primary)
                        if isClientPrice {
                            Text("client price  (default \(item.defaultPrice.currencyString))")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }

                Toggle("Override price", isOn: $useCustomPrice)
                if useCustomPrice {
                    HStack {
                        Text("$").foregroundColor(.secondary)
                        TextField("Custom price", text: $customPriceString)
                            .keyboardType(.decimalPad)
                        Text("/ \(item.unit)").foregroundColor(.secondary)
                    }
                }
            }

            // ── Quantity ──────────────────────────────────────────────────
            Section {
                HStack {
                    TextField("Enter quantity", text: $quantityString)
                        .keyboardType(.decimalPad)
                    Text(item.unit)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Quantity *")
            }

            // ── Line Total preview ────────────────────────────────────────
            if qty > 0 {
                Section {
                    HStack {
                        Text("Line Total")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(lineTotal.currencyString)
                            .font(.headline).bold().foregroundColor(.green)
                    }
                }
            }

            // ── Notes ─────────────────────────────────────────────────────
            Section("Notes (optional)") {
                TextField("e.g. Pipe 2–6\" diameter, north section", text: $itemNotes, axis: .vertical)
                    .lineLimit(1...3)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Confirm Item")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Back") {
                    withAnimation { selectedItem = nil }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    addItem(item, price: effectivePrice, qty: qty)
                }
                .bold()
                .disabled(!canAdd)
            }
        }
    }

    // MARK: Build CostCodeItem and emit

    private func addItem(_ item: ProductService, price: Decimal, qty: Decimal) {
        var desc = item.description.isEmpty ? item.name : item.description
        if !itemNotes.isEmpty { desc += " — \(itemNotes)" }

        let lineItem = CostCodeItem(
            code:              item.costCode,
            description:       desc,
            unit:              item.unit,
            estimatedQuantity: qty,
            unitRate:          price,
            productServiceID:  item.id,
            category:          item.category
        )
        onAdd(lineItem)
        dismiss()
    }
}
