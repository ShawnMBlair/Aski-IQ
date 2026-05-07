// EquipmentViews.swift
// Aski IQ – Equipment / Asset Registry Views

import SwiftUI

// MARK: - Equipment List View

struct EquipmentListView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var pagination = PaginationState(pageSize: 25)
    @State private var searchText = ""
    @State private var selectedCategory: EquipmentCategory? = nil
    @State private var selectedStatus: EquipmentStatus? = nil
    @State private var showCreate = false

    private var filtered: [Equipment] {
        store.equipment
            .filter { selectedCategory == nil || $0.category == selectedCategory }
            .filter { selectedStatus   == nil || $0.status   == selectedStatus   }
            .filter {
                searchText.isEmpty ||
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.make.localizedCaseInsensitiveContains(searchText) ||
                $0.model.localizedCaseInsensitiveContains(searchText) ||
                $0.serialNumber.localizedCaseInsensitiveContains(searchText)
            }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // Filter chips — category
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(label: "All", isSelected: selectedCategory == nil) {
                            selectedCategory = nil
                        }
                        ForEach(EquipmentCategory.allCases, id: \.self) { cat in
                            FilterChip(label: cat.displayName, isSelected: selectedCategory == cat) {
                                selectedCategory = selectedCategory == cat ? nil : cat
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }

                // Status filter row
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(label: "Any Status", isSelected: selectedStatus == nil) {
                            selectedStatus = nil
                        }
                        ForEach(EquipmentStatus.allCases, id: \.self) { status in
                            FilterChip(label: status.displayName, isSelected: selectedStatus == status) {
                                selectedStatus = selectedStatus == status ? nil : status
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }

                Divider()

                // Alerts banner
                let alerts = store.equipmentNeedingService.count + store.equipmentWithExpiringInspections.count
                if alerts > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("\(alerts) item\(alerts == 1 ? "" : "s") need attention")
                            .font(.subheadline).bold()
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.08))
                }

                if filtered.isEmpty {
                    Spacer()
                    EmptyCard(message: "No equipment found.")
                    Spacer()
                } else {
                    List {
                        ForEach(Array(filtered.prefix(pagination.displayLimit))) { item in
                            NavigationLink {
                                EquipmentDetailView(item: item)
                            } label: {
                                EquipmentRow(item: item)
                            }
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }
                        LoadMoreFooter(
                            showing: min(pagination.displayLimit, filtered.count),
                            total:   filtered.count
                        ) { pagination.loadMore() }
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $searchText, prompt: "Search equipment…")
            .onChange(of: searchText)        { _ in pagination.reset() }
            .onChange(of: selectedCategory)  { _ in pagination.reset() }
            .onChange(of: selectedStatus)    { _ in pagination.reset() }
            .navigationTitle("Equipment")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showCreate = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showCreate) {
                EquipmentCreateEditView()
                    .environmentObject(store)
            }
        }
    }
}

// MARK: - Equipment Row

struct EquipmentRow: View {
    let item: Equipment
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(categoryColor(item.category).opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: item.category.icon)
                    .foregroundColor(categoryColor(item.category))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.name)
                        .font(.headline)
                    Spacer()
                    EquipmentStatusBadge(status: item.status)
                }
                if !item.make.isEmpty || item.year != nil {
                    Text([item.year.map(String.init), item.make, item.model]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: " "))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                if !item.currentLocation.isEmpty {
                    Label(item.currentLocation, systemImage: "mappin.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Equipment Status Badge

struct EquipmentStatusBadge: View {
    let status: EquipmentStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption).bold()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .foregroundColor(color)
            .cornerRadius(8)
    }

    private var color: Color {
        switch status {
        case .available:    return .green
        case .assigned:     return .blue
        case .maintenance:  return .orange
        case .retired:      return .gray
        }
    }
}

// MARK: - Equipment Detail View

struct EquipmentDetailView: View {
    @EnvironmentObject var store: AppStore
    @State private var localItem: Equipment

    @State private var showDeletionBlocked = false
    @State private var deletionBlockedReason = ""
    @State private var showEdit = false
    @State private var showDeleteConfirm = false
    @Environment(\.dismiss) var dismiss

    init(item: Equipment) {
        _localItem = State(initialValue: item)
    }

    private var showFinancials: Bool { !store.currentUserRole.isFieldRole }

    var body: some View {
        Form {

            // MARK: Identity
            Section("Equipment Info") {
                LabeledRow(label: "Name",     value: localItem.name)
                LabeledRow(label: "Category", value: localItem.category.displayName)
                LabeledRow(label: "Status",   value: localItem.status.displayName)
                LabeledRow(label: "Ownership", value: localItem.ownership.displayName)
            }

            // MARK: Specs
            Section("Specifications") {
                if !localItem.make.isEmpty   { LabeledRow(label: "Make",   value: localItem.make) }
                if !localItem.model.isEmpty  { LabeledRow(label: "Model",  value: localItem.model) }
                if let year = localItem.year { LabeledRow(label: "Year",   value: String(year)) }
                if !localItem.serialNumber.isEmpty {
                    LabeledRow(label: "Serial #", value: localItem.serialNumber)
                }
                if !localItem.licensePlate.isEmpty {
                    LabeledRow(label: "Plate",    value: localItem.licensePlate)
                }
                if !localItem.color.isEmpty { LabeledRow(label: "Colour", value: localItem.color) }
            }

            // MARK: Location / Assignment
            Section("Assignment") {
                if localItem.status == .assigned {
                    if let projID = localItem.assignedProjectID,
                       let proj = store.projects.first(where: { $0.id == projID }) {
                        LabeledRow(label: "Project", value: proj.name)
                    }
                }
                if !localItem.currentLocation.isEmpty {
                    LabeledRow(label: "Location", value: localItem.currentLocation)
                }
            }

            // MARK: Meters
            if localItem.hourMeterReading != nil || localItem.odometerKm != nil {
                Section("Meters") {
                    if let hrs = localItem.hourMeterReading {
                        LabeledRow(label: "Hours", value: "\(hrs) hrs")
                    }
                    if let km = localItem.odometerKm {
                        LabeledRow(label: "Odometer", value: "\(km) km")
                    }
                }
            }

            // MARK: Service & Inspection
            Section("Maintenance") {
                if let d = localItem.lastServiceDate {
                    LabeledRow(label: "Last Service", value: d.shortDate)
                }
                if let d = localItem.nextServiceDate {
                    HStack {
                        Text("Next Service").foregroundColor(.secondary)
                        Spacer()
                        Text(d.shortDate)
                            .bold()
                            .foregroundColor(d < Date() ? .red : (d < Date().addingTimeInterval(30 * 86400) ? .orange : .primary))
                    }
                }
                if let d = localItem.lastInspectionDate {
                    LabeledRow(label: "Last Inspection", value: d.shortDate)
                }
                if let d = localItem.nextInspectionDate {
                    HStack {
                        Text("Next Inspection").foregroundColor(.secondary)
                        Spacer()
                        Text(d.shortDate)
                            .bold()
                            .foregroundColor(d < Date() ? .red : (d < Date().addingTimeInterval(30 * 86400) ? .orange : .primary))
                    }
                }
                if let d = localItem.insuranceExpiryDate {
                    HStack {
                        Text("Insurance Expiry").foregroundColor(.secondary)
                        Spacer()
                        Text(d.shortDate)
                            .bold()
                            .foregroundColor(d < Date() ? .red : (d < Date().addingTimeInterval(30 * 86400) ? .orange : .primary))
                    }
                }
            }

            // MARK: Financials (office only)
            if showFinancials {
                Section("Financials") {
                    if let rate = localItem.dailyRate {
                        LabeledRow(label: "Daily Rate", value: rate.currencyString)
                    }
                    if let price = localItem.purchasePrice {
                        LabeledRow(label: "Purchase Price", value: price.currencyString)
                    }
                    if let d = localItem.purchaseDate {
                        LabeledRow(label: "Purchased", value: d.shortDate)
                    }
                }
            }

            // MARK: Notes
            if !localItem.notes.isEmpty {
                Section("Notes") {
                    Text(localItem.notes)
                        .font(.subheadline)
                }
            }

            // MARK: Danger Zone
            if !store.currentUserRole.isFieldRole {
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete Equipment Record", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(localItem.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Edit") { showEdit = true }
            }
        }
        .sheet(isPresented: $showEdit) {
            EquipmentCreateEditView(existing: localItem) { updated in
                localItem = updated
                store.updateEquipment(updated)
            }
            .environmentObject(store)
        }
        .confirmationDialog("Delete \(localItem.name)?",
                             isPresented: $showDeleteConfirm,
                             titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                switch store.deleteEquipment(id: localItem.id) {
                case .success:
                    dismiss()
                case .failure(let err):
                    deletionBlockedReason = err.errorDescription ?? "Cannot delete equipment."
                    showDeletionBlocked = true
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Cannot Delete Equipment", isPresented: $showDeletionBlocked) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionBlockedReason)
        }
    }
}

// MARK: - Create / Edit View

struct EquipmentCreateEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    var existing: Equipment? = nil
    var onSave: ((Equipment) -> Void)? = nil

    // Identity
    @State private var name      = ""
    @State private var category: EquipmentCategory = .heavy
    @State private var status: EquipmentStatus = .available
    @State private var ownership: EquipmentOwnership = .owned

    // Specs
    @State private var make         = ""
    @State private var model        = ""
    @State private var yearText     = ""
    @State private var serialNumber = ""
    @State private var licensePlate = ""
    @State private var color        = ""

    // Assignment
    @State private var selectedProjectID: UUID? = nil
    @State private var currentLocation          = ""

    // Meters
    @State private var hourMeterText = ""
    @State private var odometerText  = ""

    // Dates
    @State private var hasLastService    = false;  @State private var lastService    = Date()
    @State private var hasNextService    = false;  @State private var nextService    = Date()
    @State private var hasLastInspection = false;  @State private var lastInspection = Date()
    @State private var hasNextInspection = false;  @State private var nextInspection = Date()
    @State private var hasInsuranceExpiry = false; @State private var insuranceExpiry = Date()
    @State private var hasPurchaseDate   = false;  @State private var purchaseDate   = Date()

    // Financials
    @State private var dailyRateText    = ""
    @State private var purchasePriceText = ""

    @State private var notes = ""

    private var isEditing: Bool { existing != nil }
    private var showFinancials: Bool { !store.currentUserRole.isFieldRole }

    var body: some View {
        NavigationStack {
            Form {

                Section("Identity *") {
                    TextField("Equipment Name", text: $name)
                    Picker("Category", selection: $category) {
                        ForEach(EquipmentCategory.allCases, id: \.self) { cat in
                            Text(cat.displayName).tag(cat)
                        }
                    }
                    Picker("Status", selection: $status) {
                        ForEach(EquipmentStatus.allCases, id: \.self) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    Picker("Ownership", selection: $ownership) {
                        ForEach(EquipmentOwnership.allCases, id: \.self) { o in
                            Text(o.displayName).tag(o)
                        }
                    }
                }

                Section("Specifications") {
                    TextField("Make (e.g. Caterpillar)", text: $make)
                    TextField("Model (e.g. 320)", text: $model)
                    TextField("Year", text: $yearText).keyboardType(.numberPad)
                    TextField("Serial Number", text: $serialNumber)
                    if category == .vehicle {
                        TextField("Licence Plate", text: $licensePlate)
                        TextField("Colour", text: $color)
                    }
                }

                Section("Assignment") {
                    Picker("Project", selection: $selectedProjectID) {
                        Text("None").tag(UUID?.none)
                        ForEach(store.projects.filter { $0.status == .active }) { p in
                            Text(p.name).tag(Optional(p.id))
                        }
                    }
                    TextField("Current Location", text: $currentLocation)
                }

                Section("Meters") {
                    TextField("Hour Meter (hrs)", text: $hourMeterText).keyboardType(.decimalPad)
                    TextField("Odometer (km)", text: $odometerText).keyboardType(.decimalPad)
                }

                Section("Maintenance Dates") {
                    Toggle("Last Service", isOn: $hasLastService)
                    if hasLastService { DatePicker("", selection: $lastService, displayedComponents: .date).labelsHidden() }
                    Toggle("Next Service", isOn: $hasNextService)
                    if hasNextService { DatePicker("", selection: $nextService, displayedComponents: .date).labelsHidden() }
                    Toggle("Last Inspection", isOn: $hasLastInspection)
                    if hasLastInspection { DatePicker("", selection: $lastInspection, displayedComponents: .date).labelsHidden() }
                    Toggle("Next Inspection", isOn: $hasNextInspection)
                    if hasNextInspection { DatePicker("", selection: $nextInspection, displayedComponents: .date).labelsHidden() }
                    Toggle("Insurance Expiry", isOn: $hasInsuranceExpiry)
                    if hasInsuranceExpiry { DatePicker("", selection: $insuranceExpiry, displayedComponents: .date).labelsHidden() }
                }

                if showFinancials {
                    Section("Financials") {
                        TextField("Daily Rate ($)", text: $dailyRateText).keyboardType(.decimalPad)
                        TextField("Purchase Price ($)", text: $purchasePriceText).keyboardType(.decimalPad)
                        Toggle("Purchase Date", isOn: $hasPurchaseDate)
                        if hasPurchaseDate { DatePicker("", selection: $purchaseDate, displayedComponents: .date).labelsHidden() }
                    }
                }

                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle(isEditing ? "Edit Equipment" : "New Equipment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }
                        .bold()
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { populate() }
        }
    }

    private func populate() {
        guard let e = existing else { return }
        name         = e.name
        category     = e.category
        status       = e.status
        ownership    = e.ownership
        make         = e.make
        model        = e.model
        yearText     = e.year.map(String.init) ?? ""
        serialNumber = e.serialNumber
        licensePlate = e.licensePlate
        color        = e.color
        selectedProjectID = e.assignedProjectID
        currentLocation   = e.currentLocation
        hourMeterText     = e.hourMeterReading.map { "\($0)" } ?? ""
        odometerText      = e.odometerKm.map { "\($0)" } ?? ""
        if let d = e.lastServiceDate    { hasLastService    = true; lastService    = d }
        if let d = e.nextServiceDate    { hasNextService    = true; nextService    = d }
        if let d = e.lastInspectionDate { hasLastInspection = true; lastInspection = d }
        if let d = e.nextInspectionDate { hasNextInspection = true; nextInspection = d }
        if let d = e.insuranceExpiryDate { hasInsuranceExpiry = true; insuranceExpiry = d }
        if let d = e.purchaseDate       { hasPurchaseDate   = true; purchaseDate   = d }
        dailyRateText     = e.dailyRate.map { "\($0)" } ?? ""
        purchasePriceText = e.purchasePrice.map { "\($0)" } ?? ""
        notes             = e.notes
    }

    private func save() {
        var item = existing ?? Equipment(name: name, category: category)
        item.name         = name.trimmingCharacters(in: .whitespaces)
        item.category     = category
        item.status       = status
        item.ownership    = ownership
        item.make         = make
        item.model        = model
        item.year         = Int(yearText)
        item.serialNumber = serialNumber
        item.licensePlate = licensePlate
        item.color        = color
        item.assignedProjectID = selectedProjectID
        item.currentLocation   = currentLocation
        item.hourMeterReading  = Decimal(string: hourMeterText)
        item.odometerKm        = Decimal(string: odometerText)
        item.lastServiceDate    = hasLastService    ? lastService    : nil
        item.nextServiceDate    = hasNextService    ? nextService    : nil
        item.lastInspectionDate = hasLastInspection ? lastInspection : nil
        item.nextInspectionDate = hasNextInspection ? nextInspection : nil
        item.insuranceExpiryDate = hasInsuranceExpiry ? insuranceExpiry : nil
        item.purchaseDate        = hasPurchaseDate   ? purchaseDate   : nil
        item.dailyRate    = Decimal(string: dailyRateText)
        item.purchasePrice = Decimal(string: purchasePriceText)
        item.notes        = notes

        if isEditing {
            onSave?(item)
        } else {
            store.addEquipment(item)
        }
        dismiss()
    }
}

// MARK: - Project Equipment Section (inline in ProjectDetailView)

struct ProjectEquipmentSection: View {
    let project: Project
    @EnvironmentObject var store: AppStore
    @State private var showAll = false

    private var items: [Equipment] {
        store.equipment(for: project.id).sorted { $0.name < $1.name }
    }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("Equipment", systemImage: "truck.box.fill")
                        .font(.headline)
                    Spacer()
                    if items.count > 3 {
                        Button(showAll ? "Show Less" : "Show All (\(items.count))") {
                            showAll.toggle()
                        }
                        .font(.caption)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 8)

                ForEach(showAll ? items : Array(items.prefix(3))) { item in
                    NavigationLink {
                        EquipmentDetailView(item: item)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.category.icon)
                                .foregroundColor(categoryColor(item.category))
                                .frame(width: 24)
                            Text(item.name)
                                .font(.subheadline)
                            Spacer()
                            EquipmentStatusBadge(status: item.status)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                    .foregroundColor(.primary)
                    Divider().padding(.leading, 50)
                }
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }
}

// MARK: - Helpers

private func categoryColor(_ category: EquipmentCategory) -> Color {
    switch category {
    case .heavy:   return .orange
    case .light:   return .blue
    case .vehicle: return .teal
    case .tool:    return .purple
    case .safety:  return .red
    case .other:   return .gray
    }
}

