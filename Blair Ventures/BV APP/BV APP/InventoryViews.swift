// InventoryViews.swift
// Phase 8 / Inventory v1 / Slice 2 — SwiftUI surface for the Inventory module.
//
// Views shipped here:
//   - InventoryListView           top-level list + search + + button
//   - InventoryItemDetailView     per-item detail with stock-by-location
//                                 grid + Transfer button + history
//   - InventoryItemEditorView     create / edit form (admin-gated)
//   - StockLocationListView       list + + button (admin-gated)
//   - StockLocationEditorView     create / edit location
//   - InventoryTransferCreateView form for moving stock
//   - InventoryTransfersHistoryView audit log
//
// Patterns mirror Procurement / Quote views: first-launch sync gate
// banner, role-gated `+` toolbar buttons via canPerform shim, plain
// list style, single sheet router for child sheets where applicable.

#if canImport(UIKit)
import SwiftUI
import Combine

// MARK: - InventoryListView (top-level)

struct InventoryListView: View {
    @EnvironmentObject var store: AppStore
    @State private var searchText = ""
    @State private var showCreate = false

    private var filtered: [InventoryItem] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let active = store.visibleInventoryItems
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        guard !needle.isEmpty else { return active }
        return active.filter {
            $0.name.lowercased().contains(needle)
                || $0.sku.lowercased().contains(needle)
                || $0.costCode.lowercased().contains(needle)
        }
    }

    private var canManage: Bool {
        [.officeAdmin, .manager, .executive, .owner].contains(store.currentUserRole)
    }

    var body: some View {
        VStack(spacing: 0) {
            FirstLaunchSyncGateBanner()

            Group {
                if filtered.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(filtered) { item in
                            NavigationLink {
                                InventoryItemDetailView(item: item)
                            } label: {
                                InventoryListRow(item: item)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search by SKU, name, or cost code")
        .refreshable { await store.refreshAll() }
        .navigationTitle("Inventory")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if canManage {
                    Button { showCreate = true } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!store.hasCompletedFirstSync)
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            NavigationStack {
                InventoryItemEditorView(item: InventoryItem())
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "shippingbox")
                .font(.system(size: 52))
                .foregroundColor(.secondary)
            Text("No inventory yet.")
                .font(.headline)
            Text(canManage
                 ? "Add an item to start tracking stock at your locations."
                 : "Ask an admin to set up the inventory catalog.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if canManage {
                Button("New Item") { showCreate = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.hasCompletedFirstSync)
            }
            Spacer()
        }
    }
}

// MARK: - InventoryListRow

struct InventoryListRow: View {
    @EnvironmentObject var store: AppStore
    let item: InventoryItem

    private var qtyOnHand: Decimal {
        store.totalQuantityOnHand(itemID: item.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.name).font(.body)
                Spacer()
                Text("\(qtyOnHand) \(item.unit)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(qtyOnHand > 0 ? .primary : .secondary)
            }
            HStack(spacing: 8) {
                if !item.sku.isEmpty {
                    Text(item.sku)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if !item.costCode.isEmpty {
                    Text(item.costCode)
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(4)
                }
                if !item.isActive {
                    Text("Inactive")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - InventoryItemDetailView

struct InventoryItemDetailView: View {
    @EnvironmentObject var store: AppStore
    let item: InventoryItem
    @State private var showEdit = false
    @State private var showTransfer = false

    private var stockByLocation: [(StockLocation, Decimal)] {
        store.activeStockLocations.compactMap { loc in
            let qty = store.quantityOnHand(itemID: item.id, locationID: loc.id)
            return qty > 0 ? (loc, qty) : nil
        }.sorted { $0.0.name < $1.0.name }
    }

    private var transferHistory: [InventoryTransfer] {
        store.recentInventoryTransfers
            .filter { $0.itemID == item.id }
            .prefix(20)
            .map { $0 }
    }

    private var canManage: Bool {
        [.officeAdmin, .manager, .executive, .owner].contains(store.currentUserRole)
    }

    private var canTransfer: Bool {
        [.foreman, .projectManager, .officeAdmin, .manager, .executive, .owner]
            .contains(store.currentUserRole)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !stockByLocation.isEmpty {
                    stockGrid
                } else {
                    Text("No stock on hand at any location.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding()
                }
                if canTransfer && !stockByLocation.isEmpty {
                    Button {
                        showTransfer = true
                    } label: {
                        Label("Record Transfer", systemImage: "arrow.left.arrow.right")
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .padding(.horizontal)
                }
                if !transferHistory.isEmpty {
                    historySection
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if canManage {
                    Button("Edit") { showEdit = true }
                }
            }
        }
        .sheet(isPresented: $showEdit) {
            NavigationStack {
                InventoryItemEditorView(item: item)
            }
        }
        .sheet(isPresented: $showTransfer) {
            NavigationStack {
                InventoryTransferCreateView(item: item)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.sku.isEmpty ? "(no SKU)" : item.sku)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(store.totalQuantityOnHand(itemID: item.id)) \(item.unit) total")
                    .font(.headline.monospacedDigit())
            }
            if !item.description.isEmpty {
                Text(item.description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 8) {
                if !item.costCode.isEmpty {
                    badge(item.costCode, color: .secondary)
                }
                if let cost = item.standardCost, cost > 0 {
                    badge("\(cost.currencyString)/unit", color: .secondary)
                }
                // Phase 8 / Inventory v2 — surface low-stock state so
                // the operator sees it at a glance, without having to
                // mentally compare on-hand against reorderPoint.
                if store.isLowStock(item) {
                    if let rp = item.reorderPoint {
                        badge("Low (≤\(rp))", color: .red)
                    } else {
                        badge("Out of stock", color: .red)
                    }
                }
                if !item.isActive {
                    badge("Inactive", color: .orange)
                }
            }
        }
        .padding(.horizontal)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(4)
    }

    private var stockGrid: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("On hand by location")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal)
                .padding(.bottom, 4)
            VStack(spacing: 0) {
                ForEach(stockByLocation, id: \.0.id) { (loc, qty) in
                    HStack {
                        Text(loc.displayLabel)
                        Spacer()
                        Text("\(qty) \(item.unit)")
                            .font(.body.monospacedDigit())
                    }
                    .padding(.horizontal).padding(.vertical, 8)
                    Divider()
                }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent movements")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal)
                .padding(.bottom, 4)
            VStack(spacing: 0) {
                ForEach(transferHistory) { t in
                    InventoryTransferRow(transfer: t)
                    Divider()
                }
            }
        }
    }
}

// MARK: - InventoryTransferRow

struct InventoryTransferRow: View {
    @EnvironmentObject var store: AppStore
    let transfer: InventoryTransfer

    private var fromLabel: String {
        store.activeStockLocations.first { $0.id == transfer.fromLocationID }?.displayLabel
            ?? "Unknown source"
    }

    private var toLabel: String {
        if let toLocID = transfer.toLocationID,
           let loc = store.activeStockLocations.first(where: { $0.id == toLocID }) {
            return loc.displayLabel
        }
        if let projID = transfer.toProjectID,
           let proj = store.projects.first(where: { $0.id == projID }) {
            return "→ Project: \(proj.name)"
        }
        if let mrID = transfer.toMaterialRequestID,
           let mr = store.materialRequests.first(where: { $0.id == mrID }) {
            return "→ MR: \(mr.requestNumber)"
        }
        return "Unknown destination"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(transfer.transferNumber)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                Spacer()
                Text(transfer.transferredAt, style: .date)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            HStack {
                Text("\(fromLabel) → \(toLabel)")
                    .font(.subheadline)
                    .lineLimit(2)
                Spacer()
                Text("\(transfer.quantity)")
                    .font(.subheadline.monospacedDigit())
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
    }
}

// MARK: - InventoryItemEditorView

struct InventoryItemEditorView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State var item: InventoryItem
    @State private var standardCostString: String = ""
    /// Phase 8 / Inventory v2 — reorder threshold + suggested-reorder qty
    /// captured as strings so the user can type freely; parsed into
    /// `Decimal?` at save time (empty string = nil = no threshold).
    @State private var reorderPointString: String = ""
    @State private var reorderQuantityString: String = ""

    private var isNew: Bool {
        !store.inventoryItems.contains { $0.id == item.id }
    }

    var body: some View {
        Form {
            Section("Identity") {
                TextField("SKU", text: $item.sku)
                    .autocapitalization(.allCharacters)
                    .disableAutocorrection(true)
                TextField("Name", text: $item.name)
                TextField("Unit (ea, kg, l, box, m)", text: $item.unit)
                    .autocapitalization(.none)
                TextField("Cost code", text: $item.costCode)
                    .autocapitalization(.allCharacters)
            }

            Section("Description") {
                TextField("Description", text: $item.description, axis: .vertical)
                    .lineLimit(2...4)
                TextField("Notes", text: $item.notes, axis: .vertical)
                    .lineLimit(2...4)
            }

            Section("Pricing") {
                HStack {
                    Text("Standard cost")
                    Spacer()
                    TextField("0.00", text: $standardCostString)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                }
            }

            // Phase 8 / Inventory v2 — reorder threshold UI. Leaving
            // both fields blank falls back to the v1 "qty ≤ 0" heuristic
            // so existing items keep their current behavior until the
            // admin configures explicit values.
            Section {
                HStack {
                    Text("Reorder when at or below")
                    Spacer()
                    TextField("e.g. 10", text: $reorderPointString)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 110)
                }
                HStack {
                    Text("Suggested reorder qty")
                    Spacer()
                    TextField("e.g. 50", text: $reorderQuantityString)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 110)
                }
            } header: {
                Text("Reorder thresholds")
            } footer: {
                Text("Leave blank to use the default 'out of stock' rule (qty hits zero). Suggested qty drives v2.1 auto-PO drafting.")
            }

            Section {
                Toggle("Active", isOn: $item.isActive)
            } footer: {
                Text("Inactive items are hidden from new transfers but stay in history.")
            }
        }
        .navigationTitle(isNew ? "New Item" : "Edit Item")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") { save() }
                    .disabled(item.name.trimmingCharacters(in: .whitespaces).isEmpty
                              || item.sku.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            standardCostString    = item.standardCost.map     { "\($0)" } ?? ""
            reorderPointString    = item.reorderPoint.map     { "\($0)" } ?? ""
            reorderQuantityString = item.reorderQuantity.map  { "\($0)" } ?? ""
        }
    }

    private func save() {
        item.standardCost    = Decimal(string: standardCostString.trimmingCharacters(in: .whitespaces))
        item.reorderPoint    = parsedThreshold(reorderPointString)
        item.reorderQuantity = parsedThreshold(reorderQuantityString)
        if isNew {
            store.addInventoryItem(item)
        } else {
            store.updateInventoryItem(item)
        }
        dismiss()
    }

    /// Empty input → nil (no threshold). Negative or junk inputs also
    /// flip to nil; the DB constraint `inventory_items_reorder_point_nonneg`
    /// would reject these anyway, but it's cleaner to drop them client-side.
    private func parsedThreshold(_ s: String) -> Decimal? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let d = Decimal(string: trimmed),
              d >= 0 else { return nil }
        return d
    }
}

// MARK: - StockLocationListView

struct StockLocationListView: View {
    @EnvironmentObject var store: AppStore
    @State private var showCreate = false

    private var canManage: Bool {
        [.officeAdmin, .manager, .executive, .owner].contains(store.currentUserRole)
    }

    var body: some View {
        VStack(spacing: 0) {
            FirstLaunchSyncGateBanner()
            List {
                ForEach(store.activeStockLocations.sorted { $0.name < $1.name }) { loc in
                    NavigationLink {
                        StockLocationEditorView(location: loc)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(loc.name).font(.body)
                                Spacer()
                                if loc.isDefault {
                                    Text("Default")
                                        .font(.caption)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.green.opacity(0.15))
                                        .foregroundColor(.green)
                                        .cornerRadius(4)
                                }
                            }
                            HStack(spacing: 8) {
                                if !loc.code.isEmpty {
                                    Text(loc.code)
                                        .font(.caption.monospaced())
                                        .foregroundColor(.secondary)
                                }
                                Text(loc.locationType.replacingOccurrences(of: "_", with: " "))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle("Stock Locations")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if canManage {
                    Button { showCreate = true } label: { Image(systemName: "plus") }
                        .disabled(!store.hasCompletedFirstSync)
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            NavigationStack {
                StockLocationEditorView(location: StockLocation())
            }
        }
    }
}

// MARK: - StockLocationEditorView

struct StockLocationEditorView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State var location: StockLocation

    private var isNew: Bool {
        !store.stockLocations.contains { $0.id == location.id }
    }

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $location.name)
                TextField("Code", text: $location.code)
                    .autocapitalization(.allCharacters)
                    .disableAutocorrection(true)
                Picker("Type", selection: $location.locationType) {
                    Text("Warehouse").tag("warehouse")
                    Text("Yard").tag("yard")
                    Text("Site staging").tag("site_staging")
                    Text("Mobile unit").tag("mobile")
                }
            }
            Section("Location") {
                TextField("Address", text: $location.address, axis: .vertical)
                    .lineLimit(2...3)
                TextField("Notes", text: $location.description, axis: .vertical)
                    .lineLimit(2...3)
            }
            Section {
                Toggle("Active", isOn: $location.isActive)
                Toggle("Default location for new arrivals", isOn: $location.isDefault)
            } footer: {
                Text("Only one location can be the default per company.")
            }
        }
        .navigationTitle(isNew ? "New Location" : "Edit Location")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") { save() }
                    .disabled(location.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func save() {
        if isNew { store.addStockLocation(location) } else { store.updateStockLocation(location) }
        dismiss()
    }
}

// MARK: - InventoryTransferCreateView

struct InventoryTransferCreateView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let item: InventoryItem

    @State private var fromLocationID: UUID? = nil
    @State private var destinationKind: DestinationKind = .location
    @State private var toLocationID: UUID? = nil
    @State private var toProjectID: UUID? = nil
    @State private var quantityString: String = ""
    @State private var notes: String = ""
    @State private var errorMessage: String? = nil

    enum DestinationKind: String, CaseIterable, Identifiable {
        case location, project
        var id: String { rawValue }
        var label: String {
            switch self {
            case .location: return "Another location"
            case .project:  return "Project (issue out)"
            }
        }
    }

    private var sourceLocations: [StockLocation] {
        store.locationsWithStock(itemID: item.id)
    }

    private var availableQty: Decimal {
        guard let fromID = fromLocationID else { return 0 }
        return store.quantityOnHand(itemID: item.id, locationID: fromID)
    }

    private var validationError: String? {
        guard fromLocationID != nil else { return "Pick a source location." }
        guard let qty = Decimal(string: quantityString.trimmingCharacters(in: .whitespaces)),
              qty > 0 else { return "Quantity must be > 0." }
        guard qty <= availableQty else {
            return "Only \(availableQty) \(item.unit) on hand at the selected location."
        }
        switch destinationKind {
        case .location:
            guard let toLocID = toLocationID, toLocID != fromLocationID else {
                return "Pick a destination location different from the source."
            }
        case .project:
            guard toProjectID != nil else { return "Pick a destination project." }
        }
        return nil
    }

    var body: some View {
        Form {
            Section("Item") {
                HStack {
                    Text(item.name)
                    Spacer()
                    Text("\(store.totalQuantityOnHand(itemID: item.id)) \(item.unit) total")
                        .foregroundColor(.secondary)
                }
            }

            Section("Source") {
                Picker("From", selection: $fromLocationID) {
                    Text("Pick a location").tag(UUID?.none)
                    ForEach(sourceLocations) { loc in
                        Text("\(loc.displayLabel) — \(store.quantityOnHand(itemID: item.id, locationID: loc.id)) \(item.unit)")
                            .tag(UUID?.some(loc.id))
                    }
                }
            }

            Section("Destination") {
                Picker("Type", selection: $destinationKind) {
                    ForEach(DestinationKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                switch destinationKind {
                case .location:
                    Picker("To", selection: $toLocationID) {
                        Text("Pick a location").tag(UUID?.none)
                        ForEach(store.activeStockLocations.filter { $0.id != fromLocationID }) { loc in
                            Text(loc.displayLabel).tag(UUID?.some(loc.id))
                        }
                    }
                case .project:
                    Picker("To Project", selection: $toProjectID) {
                        Text("Pick a project").tag(UUID?.none)
                        ForEach(store.projects.filter { !$0.isDeleted && $0.status != .completed }) { proj in
                            Text(proj.name).tag(UUID?.some(proj.id))
                        }
                    }
                }
            }

            Section("Quantity") {
                HStack {
                    TextField("0", text: $quantityString)
                        .keyboardType(.decimalPad)
                    Text(item.unit).foregroundColor(.secondary)
                }
                if availableQty > 0 {
                    Text("Available at source: \(availableQty) \(item.unit)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Notes (optional)") {
                TextField("Reason / context", text: $notes, axis: .vertical)
                    .lineLimit(2...4)
            }

            if let err = errorMessage ?? validationError {
                Section { Text(err).foregroundColor(.red).font(.caption) }
            }
        }
        .navigationTitle("New Transfer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") { save() }
                    .disabled(validationError != nil)
            }
        }
    }

    private func save() {
        guard let fromID = fromLocationID,
              let qty = Decimal(string: quantityString) else { return }
        let dest: InventoryTransferDestination
        switch destinationKind {
        case .location:
            guard let toID = toLocationID else { return }
            dest = .location(toID)
        case .project:
            guard let projID = toProjectID else { return }
            dest = .project(projID)
        }
        if store.recordInventoryTransfer(
            itemID: item.id,
            fromLocationID: fromID,
            destination: dest,
            quantity: qty,
            notes: notes
        ) != nil {
            ToastService.shared.success("Transfer recorded.")
            dismiss()
        } else {
            errorMessage = "Couldn't record transfer — see toast for details."
        }
    }
}

// MARK: - InventoryTransfersHistoryView

struct InventoryTransfersHistoryView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            FirstLaunchSyncGateBanner()
            List {
                ForEach(store.recentInventoryTransfers) { t in
                    InventoryTransferRow(transfer: t)
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle("Inventory Movements")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#endif
