// ProductServiceLibrary.swift
// Aski IQ – Product & Service Library + Client-Specific Pricing

import SwiftUI
import Combine

// MARK: - Product/Service Type

enum ProductServiceType: String, Codable, CaseIterable, Identifiable {
    case product = "product"
    case service = "service"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .product: return "Product"
        case .service: return "Service"
        }
    }

    var icon: String {
        switch self {
        case .product: return "shippingbox.fill"
        case .service: return "wrench.and.screwdriver.fill"
        }
    }

    var color: Color {
        switch self {
        case .product: return .blue
        case .service: return .orange
        }
    }
}

// MARK: - Product/Service Model

struct ProductService: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var type: ProductServiceType
    var costCode: String
    var description: String
    var unit: String = "hrs"
    var defaultPrice: Decimal
    var category: CostCodeCategory
    var isActive: Bool = true
    var sortOrder: Int = 0
    var syncStatus: SyncStatus = .local
    var createdAt: Date = Date()
    // MARK: Sample data tracking
    // Populated only by SampleDataSeeder; immutable post-insert via DB
    // trigger. Cleared along with the row when an executive runs Clear
    // Sample Data. See SampleData/SampleDataTypes.swift.
    var isSampleData:           Bool      = false
    var sampleDataBatchID:      UUID?     = nil
    var sampleDataSeedVersion:  String?   = nil
    var sampleDataCreatedAt:    Date?     = nil
    var sampleDataCreatedBy:    UUID?     = nil

    var updatedAt: Date = Date()
    /// Multi-tenant scope. Product/service catalog is org-wide — derived
    /// from `currentCompanyID` on upsert. Required NOT NULL server-side.
    var companyID: UUID? = nil

    init(name: String, type: ProductServiceType, costCode: String,
         description: String, unit: String = "hrs",
         defaultPrice: Decimal, category: CostCodeCategory) {
        self.name         = name
        self.type         = type
        self.costCode     = costCode
        self.description  = description
        self.unit         = unit
        self.defaultPrice = defaultPrice
        self.category     = category
    }
}

// MARK: - Client Pricing Override

struct ClientPricing: Identifiable, Codable {
    var id: UUID = UUID()
    var clientID: UUID
    var productServiceID: UUID
    var overridePrice: Decimal
    var notes: String?
    var syncStatus: SyncStatus = .local
    // MARK: Sample data tracking
    // Populated only by SampleDataSeeder; immutable post-insert via DB
    // trigger. Cleared along with the row when an executive runs Clear
    // Sample Data. See SampleData/SampleDataTypes.swift.
    var isSampleData:           Bool      = false
    var sampleDataBatchID:      UUID?     = nil
    var sampleDataSeedVersion:  String?   = nil
    var sampleDataCreatedAt:    Date?     = nil
    var sampleDataCreatedBy:    UUID?     = nil

    var updatedAt: Date = Date()

    init(clientID: UUID, productServiceID: UUID, overridePrice: Decimal, notes: String? = nil) {
        self.clientID          = clientID
        self.productServiceID  = productServiceID
        self.overridePrice     = overridePrice
        self.notes             = notes
    }
}

// MARK: - AppStore Extension

extension AppStore {

    // ── Accessors ─────────────────────────────────────────────────────────────

    var activeProductServices: [ProductService] {
        productServices
            .filter { $0.isActive }
            .sorted {
                $0.sortOrder != $1.sortOrder
                    ? $0.sortOrder < $1.sortOrder
                    : $0.name < $1.name
            }
    }

    func activeProductServices(ofType type: ProductServiceType) -> [ProductService] {
        activeProductServices.filter { $0.type == type }
    }

    /// Pricing hierarchy: client-specific override → library default price.
    func resolvedPrice(for item: ProductService, clientID: UUID?) -> Decimal {
        if let cid = clientID,
           let override = clientPricings.first(where: {
               $0.clientID == cid && $0.productServiceID == item.id
           }) {
            return override.overridePrice
        }
        return item.defaultPrice
    }

    func clientPricings(forClientID clientID: UUID) -> [ClientPricing] {
        clientPricings.filter { $0.clientID == clientID }
    }

    // ── CRUD ──────────────────────────────────────────────────────────────────

    func upsertProductService(_ item: ProductService) {
        var updated = item
        updated.syncStatus = .pending
        updated.updatedAt  = Date()
        // Stamp tenant scope (org-wide library, so currentCompanyID).
        if updated.companyID == nil { updated.companyID = currentCompanyID }
        if let idx = productServices.firstIndex(where: { $0.id == item.id }) {
            productServices[idx] = updated
        } else {
            productServices.append(updated)
        }
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPendingProductServices() }
    }

    func upsertClientPricing(_ pricing: ClientPricing) {
        var updated = pricing
        updated.syncStatus = .pending
        updated.updatedAt  = Date()
        if let idx = clientPricings.firstIndex(where: { $0.id == pricing.id }) {
            clientPricings[idx] = updated
        } else {
            clientPricings.append(updated)
        }
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPendingClientPricings() }
    }

    func deleteClientPricing(_ pricing: ClientPricing) {
        clientPricings.removeAll { $0.id == pricing.id }
        objectWillChange.send()
    }
}

// MARK: - Product/Service List View (Settings)

struct ProductServiceListView: View {
    @EnvironmentObject var store: AppStore
    @State private var showCreate    = false
    @State private var editingItem: ProductService? = nil
    @State private var searchText   = ""
    @State private var typeFilter: ProductServiceType? = nil

    private var filtered: [ProductService] {
        store.activeProductServices.filter { item in
            (typeFilter == nil || item.type == typeFilter) &&
            (searchText.isEmpty ||
                item.name.localizedCaseInsensitiveContains(searchText) ||
                item.costCode.localizedCaseInsensitiveContains(searchText) ||
                item.description.localizedCaseInsensitiveContains(searchText) ||
                item.category.rawValue.localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        List {
            // Type filter pills
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

            if filtered.isEmpty {
                if store.activeProductServices.isEmpty {
                    ContentUnavailableView(
                        "No Items Yet",
                        systemImage: "shippingbox",
                        description: Text("Tap + to add your first product or service.")
                    )
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            } else {
                ForEach(filtered) { item in
                    Button { editingItem = item } label: {
                        PSLibraryRow(item: item, clientPrice: nil)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "Search name, code, or category…")
        .navigationTitle("Products & Services")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showCreate = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showCreate) {
            ProductServiceCreateEditView(item: nil)
        }
        .sheet(item: $editingItem) { item in
            ProductServiceCreateEditView(item: item)
        }
    }
}

// MARK: - Library Row (reused in picker + list)

struct PSLibraryRow: View {
    let item: ProductService
    let clientPrice: Decimal?   // non-nil = client override price exists

    var body: some View {
        HStack(spacing: 12) {
            // Type badge
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(item.type.color.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: item.type.icon)
                    .foregroundColor(item.type.color)
                    .font(.system(size: 16))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.costCode)
                        .font(.caption2).bold()
                        .fontDesign(.monospaced)
                        .foregroundColor(.secondary)
                    Text(item.name)
                        .font(.subheadline).fontWeight(.semibold)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(item.category.color)
                        .frame(width: 6, height: 6)
                    Text(item.category.rawValue)
                        .font(.caption2)
                        .foregroundColor(item.category.color)
                    Text("·").foregroundColor(.secondary).font(.caption2)
                    Text(item.unit)
                        .font(.caption2).foregroundColor(.secondary)
                }
                if !item.description.isEmpty {
                    Text(item.description)
                        .font(.caption2).foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let cp = clientPrice {
                    Text(cp.currencyString)
                        .font(.subheadline).bold().foregroundColor(.green)
                    Text("client").font(.caption2).foregroundColor(.secondary)
                } else {
                    Text(item.defaultPrice.currencyString)
                        .font(.subheadline).bold()
                    Text("/ \(item.unit)").font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Create / Edit View

struct ProductServiceCreateEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    var item: ProductService?
    private var isEditing: Bool { item != nil }

    @State private var name         = ""
    @State private var type         = ProductServiceType.service
    @State private var costCode     = ""
    @State private var description  = ""
    @State private var unit         = "hrs"
    @State private var priceString  = "0"
    @State private var category     = CostCodeCategory.labour
    @State private var isActive     = true
    @State private var showCodePicker  = false
    @State private var showValidation  = false

    private let units = ["hrs", "ea", "lm", "m²", "m³", "tonne", "day", "ls", "wk", "month"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Type") {
                    Picker("Type", selection: $type) {
                        ForEach(ProductServiceType.allCases) { t in
                            Label(t.displayName, systemImage: t.icon).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    TextField("Name", text: $name)
                    HStack {
                        TextField("Cost Code", text: $costCode)
                            .fontDesign(.monospaced)
                        Button("Pick") { showCodePicker = true }
                            .font(.caption).foregroundColor(.blue)
                    }
                    Picker("Category", selection: $category) {
                        ForEach(CostCodeCategory.allCases) { cat in
                            Text(cat.rawValue).tag(cat)
                        }
                    }
                } header: {
                    Text("Identity *")
                }

                Section("Details") {
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                    Picker("Unit of Measure", selection: $unit) {
                        ForEach(units, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    HStack {
                        Text("$").foregroundColor(.secondary)
                        TextField("Default Price", text: $priceString)
                            .keyboardType(.decimalPad)
                        Text("per \(unit)").foregroundColor(.secondary)
                    }
                }

                if isEditing {
                    Section {
                        Toggle("Active", isOn: $isActive)
                    } footer: {
                        Text("Inactive items are hidden from the picker but their history is preserved.")
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Item" : "New Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.bold()
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  costCode.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert("Missing Info", isPresented: $showValidation) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Name and cost code are required.")
            }
            .sheet(isPresented: $showCodePicker) {
                CostCodePickerSheet(projectID: nil) { selected in
                    costCode    = selected.code
                    category    = selected.category
                    if description.isEmpty { description = selected.description }
                }
            }
            .onAppear { populate() }
        }
        .presentationDetents([.large])
    }

    private func populate() {
        guard let item else { return }
        name        = item.name
        type        = item.type
        costCode    = item.costCode
        description = item.description
        unit        = item.unit
        priceString = NSDecimalNumber(decimal: item.defaultPrice).stringValue
        category    = item.category
        isActive    = item.isActive
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        let c = costCode.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !c.isEmpty else { showValidation = true; return }

        let price = Decimal(string: priceString) ?? 0

        if var existing = item {
            existing.name         = n
            existing.type         = type
            existing.costCode     = c
            existing.description  = description
            existing.unit         = unit
            existing.defaultPrice = price
            existing.category     = category
            existing.isActive     = isActive
            store.upsertProductService(existing)
        } else {
            let ps = ProductService(
                name: n, type: type, costCode: c,
                description: description, unit: unit,
                defaultPrice: price, category: category
            )
            store.upsertProductService(ps)
        }
        dismiss()
    }
}

// MARK: - Filter Chip (scoped to PS module to avoid collisions)

struct PSFilterChip: View {
    let label: String
    var icon: String? = nil
    var color: Color  = .blue
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.caption2) }
                Text(label).font(.caption).fontWeight(.semibold)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(isSelected ? color.opacity(0.15) : Color(.systemGray5))
            .foregroundColor(isSelected ? color : .primary)
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isSelected ? color.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sample-data tracking
extension ProductService: SampleDataTrackable {}

// MARK: - Sample-data tracking
extension ClientPricing: SampleDataTrackable {}
