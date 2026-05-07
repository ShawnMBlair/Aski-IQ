// CostCodeSettingsView.swift
// Aski IQ – Cost Code Management (Admin / Manager only)

import SwiftUI

struct CostCodeSettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var showAddSheet = false
    @State private var expandedCategories: Set<CostCodeCategory> = []
    @State private var searchText = ""
    /// Slice C: cost code being edited for service-type assignment.
    /// Drives the inline sheet so the user doesn't lose their place
    /// in the long category list.
    @State private var serviceTypesEditTarget: CompanyCostCode? = nil

    private var canEdit: Bool {
        store.currentUserRole.canManageUsers
    }

    private var categories: [CostCodeCategory] {
        CostCodeCategory.allCases
    }

    private func codes(in category: CostCodeCategory) -> [CompanyCostCode] {
        store.companyCostCodes
            .filter { $0.category == category }
            .filter {
                searchText.isEmpty ||
                $0.code.localizedCaseInsensitiveContains(searchText) ||
                $0.description.localizedCaseInsensitiveContains(searchText)
            }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private func isCategoryEnabled(_ cat: CostCodeCategory) -> Bool {
        codes(in: cat).contains { $0.isEnabled }
    }

    var body: some View {
        List {
            if !canEdit {
                Section {
                    Label("Only managers and admins can edit cost codes.",
                          systemImage: "lock.fill")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            ForEach(categories, id: \.self) { category in
                let catCodes = codes(in: category)
                let enabled  = isCategoryEnabled(category)
                let expanded = expandedCategories.contains(category)

                Section {
                    // Category header row
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(category.color.opacity(0.12))
                                .frame(width: 36, height: 36)
                            Image(systemName: category.icon)
                                .foregroundColor(category.color)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.rawValue)
                                .font(.headline)
                            Text("\(catCodes.filter(\.isEnabled).count) of \(catCodes.count) enabled")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if canEdit {
                            Toggle("", isOn: Binding(
                                get: { enabled },
                                set: { store.toggleCategory(category, enabled: $0) }
                            ))
                            .labelsHidden()
                        }

                        Button {
                            withAnimation {
                                if expanded { expandedCategories.remove(category) }
                                else        { expandedCategories.insert(category) }
                            }
                        } label: {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)

                    // Expanded individual codes
                    if expanded {
                        ForEach(catCodes) { code in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(code.code)
                                        .font(.system(.subheadline, design: .monospaced))
                                        .bold()
                                        .foregroundColor(code.isEnabled ? .primary : .secondary)
                                    Text(code.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    // Slice C: tappable service-types chip.
                                    // Shows current tags or "Tag for T&C
                                    // suggestions" when empty.
                                    if canEdit {
                                        Button {
                                            serviceTypesEditTarget = code
                                        } label: {
                                            serviceTypesChip(code)
                                        }
                                        .buttonStyle(.plain)
                                    } else if !code.serviceTypes.isEmpty {
                                        serviceTypesChip(code)
                                    }
                                }

                                Spacer()

                                if code.isCustom {
                                    Text("Custom")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.15))
                                        .foregroundColor(.orange)
                                        .cornerRadius(4)
                                }

                                if canEdit {
                                    Toggle("", isOn: Binding(
                                        get: { code.isEnabled },
                                        set: { _ in store.toggleCostCode(code) }
                                    ))
                                    .labelsHidden()
                                }
                            }
                            .padding(.leading, 48)
                        }
                        .onDelete(perform: canEdit ? { offsets in
                            let toDelete = offsets.map { catCodes[$0] }.filter(\.isCustom)
                            toDelete.forEach { store.deleteCostCode($0) }
                        } : nil)
                    }

                } header: { EmptyView() }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "Search codes…")
        .navigationTitle("Cost Codes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddCostCodeSheet()
                .environmentObject(store)
        }
        .sheet(item: $serviceTypesEditTarget) { code in
            CostCodeServiceTypesSheet(code: code)
                .environmentObject(store)
        }
        .onAppear {
            store.seedCostCodesIfNeeded()
        }
    }

    /// Slice C: tiny chip rendered under each cost code's description.
    /// Shows the assigned service types as a short comma list, or a
    /// "tag" prompt when empty so admins know where to start.
    @ViewBuilder
    private func serviceTypesChip(_ code: CompanyCostCode) -> some View {
        if code.serviceTypes.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "tag")
                Text("Tag for T&C suggestions")
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        } else {
            HStack(spacing: 4) {
                Image(systemName: "tag.fill")
                    .foregroundColor(.blue)
                Text(code.serviceTypes.map { $0.displayName }.joined(separator: " · "))
                    .foregroundColor(.blue)
                    .lineLimit(1)
            }
            .font(.caption2)
        }
    }
}

// MARK: - Service Types editor (Slice C)

/// Per-cost-code multi-select for ServiceType. Drives Slice C's
/// auto-suggestion: any quote line item using this code will surface
/// terms_templates whose `applies_to_service_types` overlaps with this
/// list. Saving stamps syncStatus = .pending so the change flows through
/// pushCostCode on the next sync.
struct CostCodeServiceTypesSheet: View {
    let code: CompanyCostCode
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<ServiceType> = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Code", value: code.code)
                    LabeledContent("Description", value: code.description)
                    LabeledContent("Category", value: code.category.rawValue)
                }

                Section {
                    ForEach(ServiceType.allCases) { st in
                        Button {
                            toggle(st)
                        } label: {
                            HStack {
                                Image(systemName: selected.contains(st)
                                      ? "checkmark.circle.fill"
                                      : "circle")
                                    .foregroundColor(selected.contains(st) ? .blue : .secondary)
                                Text(st.displayName)
                                    .foregroundColor(.primary)
                                Spacer()
                            }
                        }
                    }
                } header: {
                    Text("Service Types")
                } footer: {
                    Text("Quotes containing line items with this cost code will surface Terms & Conditions templates whose 'Auto-suggest for Service Types' includes any of these tags. Leave empty to skip auto-suggestion for this code.")
                        .font(.caption)
                }
            }
            .navigationTitle("Service Type Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }.bold()
                }
            }
            .onAppear { selected = Set(code.serviceTypes) }
        }
    }

    private func toggle(_ st: ServiceType) {
        if selected.contains(st) { selected.remove(st) }
        else                      { selected.insert(st) }
    }

    private func save() {
        var updated = code
        updated.serviceTypes = ServiceType.allCases.filter { selected.contains($0) }
        updated.syncStatus = .pending
        store.upsertCostCode(updated)
        dismiss()
    }
}

// MARK: - Add Custom Code Sheet

struct AddCostCodeSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var code        = ""
    @State private var description = ""
    @State private var category: CostCodeCategory = .labour
    @State private var errorMsg: String? = nil

    private var isValid: Bool {
        !code.trimmingCharacters(in: .whitespaces).isEmpty &&
        !description.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Code") {
                    TextField("e.g. INS-008", text: $code)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                }

                Section("Description") {
                    TextField("e.g. Cryogenic Pipe Wrap", text: $description)
                }

                Section("Category") {
                    Picker("Category", selection: $category) {
                        ForEach(CostCodeCategory.allCases) { cat in
                            Label(cat.rawValue, systemImage: cat.icon)
                                .tag(cat)
                        }
                    }
                    .pickerStyle(.menu)
                }

                if let err = errorMsg {
                    Section {
                        Text(err).foregroundColor(.red).font(.caption)
                    }
                }
            }
            .navigationTitle("Add Cost Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") { save() }
                        .bold()
                        .disabled(!isValid)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let trimmedCode = code.trimmingCharacters(in: .whitespaces).uppercased()
        if store.companyCostCodes.contains(where: { $0.code == trimmedCode }) {
            errorMsg = "Code \(trimmedCode) already exists."
            return
        }
        let next = (store.companyCostCodes.map(\.sortOrder).max() ?? 0) + 1
        let newCode = CompanyCostCode(
            companyID:   store.currentCompanyID,
            code:        trimmedCode,
            description: description.trimmingCharacters(in: .whitespaces),
            category:    category,
            isEnabled:   true,
            isCustom:    true,
            sortOrder:   next,
            syncStatus:  .pending
        )
        store.upsertCostCode(newCode)
        dismiss()
    }
}
