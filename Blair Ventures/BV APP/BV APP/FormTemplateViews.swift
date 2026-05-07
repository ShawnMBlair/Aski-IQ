// FormTemplateViews.swift
// FieldOS – Full Form Builder (Salus Pro style)

import SwiftUI

/// Wraps a UUID so it can be used with .sheet(item:)
struct IdentifiableID: Identifiable {
    let id: UUID
}

// MARK: - Form Template List

struct FormTemplateListView: View {
    @EnvironmentObject var store: AppStore
    @State private var showCreate = false
    @State private var searchText = ""
    @State private var selectedCategory: String? = nil

    private var categories: [String] {
        let cats = store.formTemplates.compactMap { $0.category }
        return Array(Set(cats)).sorted()
    }

    private var filtered: [FormTemplate] {
        store.formTemplates
            .filter { $0.isActive }
            .filter { selectedCategory == nil || $0.category == selectedCategory }
            .filter {
                searchText.isEmpty ||
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                ($0.category ?? "").localizedCaseInsensitiveContains(searchText)
            }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Category filter pills
                if !categories.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            FilterPill(label: "All", isSelected: selectedCategory == nil) {
                                selectedCategory = nil
                            }
                            ForEach(categories, id: \.self) { cat in
                                FilterPill(label: cat, isSelected: selectedCategory == cat) {
                                    selectedCategory = selectedCategory == cat ? nil : cat
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                    Divider()
                }

                if filtered.isEmpty {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "doc.text.below.ecg")
                            .font(.system(size: 52))
                            .foregroundColor(.secondary)
                        Text("No form templates yet.")
                            .font(.headline)
                        Text("Tap + to build your first template.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Button("Create Template") { showCreate = true }
                            .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(filtered) { template in
                            NavigationLink {
                                FormTemplateBuilderView(existing: template)
                            } label: {
                                FormTemplateRow(template: template)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.deleteFormTemplate(template)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    duplicateTemplate(template)
                                } label: {
                                    Label("Duplicate", systemImage: "doc.on.doc")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $searchText, prompt: "Search templates")
            .navigationTitle("Form Templates")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showCreate = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showCreate) {
                FormTemplateBuilderView()
            }
            .onAppear { loadSampleTemplatesIfNeeded() }
        }
    }

    private func duplicateTemplate(_ original: FormTemplate) {
        var copy = original
        copy.id = UUID()
        copy.name = original.name + " (Copy)"
        copy.createdAt = Date()
        copy.updatedAt = Date()
        copy.syncStatus = .pending
        store.upsertFormTemplate(copy)
    }

    private func loadSampleTemplatesIfNeeded() {
        FormTemplateSeed.seedIfNeeded(into: store)
    }
}

// MARK: - Form Template Seed
// Accessible from any view — seeds starter templates if not already present

enum FormTemplateSeed {

    static func seedIfNeeded(into store: AppStore) {
        if !store.formTemplates.contains(where: { $0.name == "Daily Hazard Assessment" }) {
            store.upsertFormTemplate(buildHazardAssessment())
        }
        if !store.formTemplates.contains(where: { $0.name == "Daily Field Report" }) {
            store.upsertFormTemplate(buildDailyFieldReport())
        }
    }

    // MARK: - Daily Hazard Assessment

    static func buildHazardAssessment() -> FormTemplate {
        var t = FormTemplate(name: "Daily Hazard Assessment")
        t.category = "Safety"
        t.requiresSignature = true
        t.formDescription = "Complete before starting work each day."
        t.syncStatus = .pending
        t.fields = [
            FormField(label: "Site Conditions",                  type: .sectionHeader, sortOrder: 0),
            FormField(label: "Are all PPE requirements met?",    type: .yesNo,  isRequired: true,  sortOrder: 1),
            FormField(label: "Any hazards identified on site?",  type: .yesNo,  isRequired: true,  sortOrder: 2),
            FormField(label: "Hazard description",               type: .longText, sortOrder: 3,
                      hint: "Describe any hazards found above"),
            FormField(label: "Weather conditions",               type: .singleChoice, isRequired: true,
                      sortOrder: 4, options: ["Clear", "Cloudy", "Rain", "Wind", "Snow", "Extreme Heat"]),
            FormField(label: "Site photo",                       type: .photo,  sortOrder: 5)
        ]
        return t
    }

    // MARK: - Daily Field Report
    // Mapped from Salus Pro JSON schema (version 2)
    // table → sectionHeader + longText (Material, Equipment)
    // pre-filled table rows → individual number fields (Time Tracking)

    static func buildDailyFieldReport() -> FormTemplate {
        var t = FormTemplate(name: "Daily Field Report")
        t.category = "Field Operations"
        t.formDescription = "Daily report of crew, weather, work performed, materials and equipment."
        t.requiresSignature = false
        t.syncStatus = .pending

        var fields: [FormField] = []
        var s = 0   // sortOrder counter

        // ── Row 1: Name | Date ──
        var fName = FormField(label: "Name", type: .shortText, sortOrder: s); s += 1
        fName.autoVariable = .userName
        fName.columnWidth  = .half
        fields.append(fName)

        var fDate = FormField(label: "Date", type: .date, sortOrder: s); s += 1
        fDate.autoVariable = .currentDate
        fDate.columnWidth  = .half
        fields.append(fDate)

        // ── Row 2: Crew Size | Temperature ──
        var fCrew = FormField(label: "Crew Size", type: .number, isRequired: true, sortOrder: s); s += 1
        fCrew.columnWidth = .half
        fCrew.unit        = "people"
        fields.append(fCrew)

        var fTemp = FormField(label: "Temperature", type: .shortText, sortOrder: s); s += 1
        fTemp.columnWidth = .half
        fTemp.hint        = "e.g. 18°C"
        fields.append(fTemp)

        // ── Row 3: No. Absent | Weather ──
        var fAbsent = FormField(label: "No. Absent", type: .number, sortOrder: s); s += 1
        fAbsent.columnWidth = .half
        fields.append(fAbsent)

        var fWeather = FormField(label: "Weather", type: .shortText, sortOrder: s); s += 1
        fWeather.columnWidth = .half
        fWeather.hint        = "e.g. Sunny, Cloudy, Rain"
        fields.append(fWeather)

        // ── Row 4: Incidents | Wind ──
        var fIncidents = FormField(label: "Incidents", type: .yesNo, sortOrder: s); s += 1
        fIncidents.columnWidth = .half
        fields.append(fIncidents)

        var fWind = FormField(label: "Wind", type: .shortText, sortOrder: s); s += 1
        fWind.columnWidth = .half
        fWind.hint        = "e.g. Calm, Light, Strong"
        fields.append(fWind)

        // ── Issues (multi-select, full width) ──
        var fIssues = FormField(label: "Issues", type: .multipleChoice, sortOrder: s); s += 1
        fIssues.columnWidth = .full
        fIssues.options     = ["Equipment Failure", "Weather Delay", "Material Shortage",
                               "Staffing", "Safety Concern", "Other"]
        fIssues.hint        = "Select all that apply"
        fields.append(fIssues)

        // ── Work Performed Today ──
        var fWork = FormField(label: "Work Performed Today", type: .longText, sortOrder: s); s += 1
        fWork.columnWidth = .full
        fWork.hint        = "Describe all work completed on site today"
        fields.append(fWork)

        // ── Delays ──
        var fDelays = FormField(label: "Delays", type: .longText, sortOrder: s); s += 1
        fDelays.columnWidth = .full
        fDelays.hint        = "Describe any delays encountered"
        fields.append(fDelays)

        // ── Material Used (table → section header + longText) ──
        var fMatHeader = FormField(label: "Material Used", type: .sectionHeader, sortOrder: s); s += 1
        fMatHeader.columnWidth = .full
        fields.append(fMatHeader)

        var fMat = FormField(label: "Material / Units", type: .longText, isRequired: true, sortOrder: s); s += 1
        fMat.columnWidth = .full
        fMat.hint        = "List each material and quantity on a new line\ne.g. Poly Sheeting – 5 rolls\nIso Wool – 12 bags"
        fields.append(fMat)

        // ── Equipment and Hours (table → section header + longText) ──
        var fEqHeader = FormField(label: "Equipment and Hours", type: .sectionHeader, sortOrder: s); s += 1
        fEqHeader.columnWidth = .full
        fields.append(fEqHeader)

        var fEq = FormField(label: "Equipment / Hours", type: .longText, sortOrder: s); s += 1
        fEq.columnWidth = .full
        fEq.hint        = "List each piece of equipment and hours used\ne.g. Scissor Lift – 4 hrs\nForklift – 2 hrs"
        fields.append(fEq)

        // ── Time Tracking Tasks (pre-filled rows → section header + number fields) ──
        var fTimeHeader = FormField(label: "Time Tracking", type: .sectionHeader, sortOrder: s); s += 1
        fTimeHeader.columnWidth = .full
        fields.append(fTimeHeader)

        let taskNames = [
            "Morning Paperwork",
            "Setup and Prep Work",
            "Installing Sheets",
            "Shrinking Material",
            "Clean Up",
            "Shop / Office"
        ]
        for name in taskNames {
            var tf = FormField(label: name, type: .number, sortOrder: s); s += 1
            tf.columnWidth = .half
            tf.unit        = "hrs"
            fields.append(tf)
        }

        // ── Site Pictures ──
        var fPhotos = FormField(label: "Site Pictures", type: .photo, sortOrder: s); s += 1
        fPhotos.columnWidth = .full
        fields.append(fPhotos)

        t.fields = fields

        // Single group "Form Details" — mirrors structure.main.groups[0]
        var group = FieldGroup(name: "Form Details")
        group.fieldIDs = fields.map { $0.id }
        t.groups = [group]

        return t
    }
}

// MARK: - Filter Pill

struct FilterPill: View {
    let label: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(label)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.blue : Color(.secondarySystemBackground))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(20)
        }
    }
}

// MARK: - Template Row

struct FormTemplateRow: View {
    let template: FormTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(template.name).font(.headline)
                Spacer()
                if template.requiresSignature {
                    Image(systemName: "signature")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
            HStack(spacing: 8) {
                if let category = template.category {
                    Text(category)
                        .font(.caption)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .cornerRadius(6)
                }
                let fieldCount = template.fields.filter { !$0.type.isLayoutOnly }.count
                Text("\(fieldCount) field\(fieldCount == 1 ? "" : "s")")
                    .font(.caption).foregroundColor(.secondary)
                if template.version > 1 {
                    Text("v\(template.version)")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            if let desc = template.formDescription, !desc.isEmpty {
                Text(desc)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Form Template Builder

struct FormTemplateBuilderView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    var existing: FormTemplate? = nil

    @State private var name = ""
    @State private var category = ""
    @State private var formDescription = ""
    @State private var requiresSignature = false
    @State private var fields: [FormField] = []
    @State private var groups: [FieldGroup] = []

    // Sheet / state control
    @State private var selectedTab: BuilderTab = .fields
    @State private var showFieldPicker = false
    @State private var editingField: FormField? = nil
    @State private var showValidationError = false
    @State private var validationMessage = ""
    @State private var showPreview = false
    // Group editing
    @State private var showAddGroup = false
    @State private var editingGroupID: UUID? = nil
    @State private var newGroupName = ""
    @State private var showFieldAssigner: IdentifiableID? = nil  // groupID to assign fields into

    enum BuilderTab { case fields, groups, settings }

    private var isEditing: Bool { existing != nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab picker
                Picker("Tab", selection: $selectedTab) {
                    Text("Fields").tag(BuilderTab.fields)
                    Text("Groups").tag(BuilderTab.groups)
                    Text("Settings").tag(BuilderTab.settings)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                // Tab content
                switch selectedTab {
                case .fields:  fieldsTab
                case .groups:  groupsTab
                case .settings: settingsTab
                }
            }
            .navigationTitle(isEditing ? "Edit Template" : "New Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        if !fields.isEmpty {
                            Button { showPreview = true } label: {
                                Image(systemName: "eye")
                            }
                        }
                        Button("Save") { save() }.bold()
                    }
                }
            }
            .alert("Missing Info", isPresented: $showValidationError) {
                Button("OK", role: .cancel) {}
            } message: { Text(validationMessage) }
            .sheet(isPresented: $showFieldPicker) {
                FieldTypePicker { newField in
                    fields.append(newField)
                    editingField = newField
                }
            }
            .sheet(item: $editingField) { field in
                FieldEditorSheet(field: field) { updated in
                    if let idx = fields.firstIndex(where: { $0.id == updated.id }) {
                        fields[idx] = updated
                    }
                }
            }
            .sheet(isPresented: $showPreview) {
                let previewTemplate = buildTemplate()
                FormSubmissionView(template: previewTemplate, isPreview: true)
            }
            .sheet(isPresented: $showAddGroup) {
                addGroupSheet
            }
            .sheet(item: $showFieldAssigner) { wrapper in
                FieldAssignerSheet(
                    groupID: wrapper.id,
                    allFields: fields,
                    groups: $groups
                )
            }
            .onAppear { populate() }
        }
    }

    // MARK: - Fields Tab

    private var fieldsTab: some View {
        List {
            if fields.isEmpty {
                Button { showFieldPicker = true } label: {
                    Label("Add First Field", systemImage: "plus.circle.fill")
                        .foregroundColor(.blue)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 6)
                }
            } else {
                Section {
                    ForEach(fields) { field in
                        FieldBuilderRow(field: field)
                            .contentShape(Rectangle())
                            .onTapGesture { editingField = field }
                    }
                    .onDelete { indices in fields.remove(atOffsets: indices) }
                    .onMove  { from, to in fields.move(fromOffsets: from, toOffset: to) }

                    Button { showFieldPicker = true } label: {
                        Label("Add Field", systemImage: "plus.circle")
                            .foregroundColor(.blue)
                    }
                } header: {
                    HStack {
                        Text("\(fields.filter { !$0.type.isLayoutOnly }.count) input fields · \(fields.count) total")
                        Spacer()
                        EditButton().font(.caption)
                    }
                } footer: {
                    Text("Tap a field to edit its label, type, and options. Drag to reorder.")
                        .font(.caption2)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Groups Tab

    private var groupsTab: some View {
        List {
            if groups.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "rectangle.3.group")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text("No groups yet")
                            .font(.headline)
                        Text("Groups let you organise fields into named sections, like Salus. Each group becomes a titled section on the form.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Create First Group") { showAddGroup = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
            } else {
                ForEach(groups) { group in
                    Section {
                        // Fields assigned to this group
                        let groupFields = group.fieldIDs.compactMap { fid in
                            fields.first { $0.id == fid }
                        }
                        if groupFields.isEmpty {
                            Text("No fields yet — tap Assign Fields")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(groupFields) { field in
                                FieldBuilderRow(field: field)
                                    .contentShape(Rectangle())
                                    .onTapGesture { editingField = field }
                            }
                            .onMove { from, to in
                                if let gIdx = groups.firstIndex(where: { $0.id == group.id }) {
                                    groups[gIdx].fieldIDs.move(fromOffsets: from, toOffset: to)
                                }
                            }
                            .onDelete { offsets in
                                if let gIdx = groups.firstIndex(where: { $0.id == group.id }) {
                                    groups[gIdx].fieldIDs.remove(atOffsets: offsets)
                                }
                            }
                        }

                        Button {
                            showFieldAssigner = IdentifiableID(id: group.id)
                        } label: {
                            Label("Assign Fields", systemImage: "plus.circle")
                                .font(.subheadline)
                                .foregroundColor(.blue)
                        }
                    } header: {
                        HStack {
                            Image(systemName: "rectangle.3.group.fill")
                                .foregroundColor(.blue)
                                .font(.caption)
                            Text(group.name)
                                .font(.subheadline)
                                .bold()
                            Spacer()
                            Button {
                                editingGroupID = group.id
                                newGroupName = group.name
                                showAddGroup = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Button(role: .destructive) {
                                groups.removeAll { $0.id == group.id }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }
                .onMove { from, to in groups.move(fromOffsets: from, toOffset: to) }
            }

            Section {
                Button { showAddGroup = true } label: {
                    Label("Add Group", systemImage: "plus.circle")
                        .foregroundColor(.blue)
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(.active))
    }

    // MARK: - Settings Tab

    private var settingsTab: some View {
        Form {
            Section("Template Info") {
                TextField("Template Name *", text: $name)
                TextField("Category (e.g. Safety, Quality, HR)", text: $category)
                TextField("Description shown before filling", text: $formDescription)
                Toggle("Requires Signature", isOn: $requiresSignature)
            }

            if isEditing {
                Section {
                    Button(role: .destructive) {
                        if let t = existing {
                            store.deleteFormTemplate(t)
                            dismiss()
                        }
                    } label: {
                        Label("Delete Template", systemImage: "trash")
                    }
                }
            }
        }
    }

    // MARK: - Add / Edit Group Sheet

    private var addGroupSheet: some View {
        NavigationStack {
            Form {
                Section("Group Name") {
                    TextField("e.g. Site Conditions, Worker Info", text: $newGroupName)
                }
            }
            .navigationTitle(editingGroupID == nil ? "New Group" : "Rename Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        showAddGroup = false
                        editingGroupID = nil
                        newGroupName = ""
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        let trimmed = newGroupName.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        if let gid = editingGroupID,
                           let idx = groups.firstIndex(where: { $0.id == gid }) {
                            groups[idx].name = trimmed
                        } else {
                            groups.append(FieldGroup(name: trimmed))
                        }
                        showAddGroup = false
                        editingGroupID = nil
                        newGroupName = ""
                    }
                    .bold()
                    .disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.height(200)])
    }

    // MARK: - Populate

    private func populate() {
        guard let t = existing else { return }
        name = t.name
        category = t.category ?? ""
        formDescription = t.formDescription ?? ""
        requiresSignature = t.requiresSignature
        fields = t.fields.sorted { $0.sortOrder < $1.sortOrder }
        groups = t.groups
    }

    private func buildTemplate() -> FormTemplate {
        var template = existing ?? FormTemplate(name: name)
        template.name = name
        template.category = category.isEmpty ? nil : category
        template.formDescription = formDescription.isEmpty ? nil : formDescription
        template.requiresSignature = requiresSignature
        template.fields = fields.enumerated().map { idx, f in
            var mf = f; mf.sortOrder = idx; return mf
        }
        template.groups = groups
        return template
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationMessage = "Template name is required."
            showValidationError = true
            return
        }
        var template = buildTemplate()
        template.updatedAt = Date()
        template.lastModifiedAt = Date()
        template.syncStatus = .pending
        if isEditing { template.version = (existing?.version ?? 1) + 1 }

        store.upsertFormTemplate(template)
        dismiss()
    }
}

// MARK: - Field Builder Row (in template list)

struct FieldBuilderRow: View {
    let field: FormField

    var body: some View {
        HStack(spacing: 12) {
            // Type icon
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(field.type.isLayoutOnly ? Color.orange.opacity(0.12) : Color.blue.opacity(0.12))
                    .frame(width: 34, height: 34)
                Image(systemName: field.type.icon)
                    .font(.system(size: 15))
                    .foregroundColor(field.type.isLayoutOnly ? .orange : .blue)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(field.label)
                    .font(.subheadline)
                    .fontWeight(field.type == .sectionHeader ? .bold : .regular)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(field.type.displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if field.isRequired {
                        Text("Required")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.red.opacity(0.1))
                            .foregroundColor(.red)
                            .cornerRadius(4)
                    }
                    if field.columnWidth == .half {
                        Image(systemName: "rectangle.split.2x1")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if field.autoVariable != nil {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                            .foregroundColor(.yellow)
                    }
                    if field.permission == .none {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if field.condition != nil {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption2)
                            .foregroundColor(.purple)
                    }
                }
            }

            Spacer()
            Image(systemName: "pencil")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Field Type Picker Sheet

struct FieldTypePicker: View {
    let onSelect: (FormField) -> Void
    @Environment(\.dismiss) var dismiss

    private let grouped: [(FieldTypeCategory, [FormFieldType])] = [
        (.layout,  [.sectionHeader, .instructions]),
        (.input,   [.shortText, .longText, .number, .date, .time, .dateTime]),
        (.choice,  [.yesNo, .yesNoNA, .passFail, .passFailNA, .singleChoice, .multipleChoice, .dropdown]),
        (.scale,   [.rating, .slider]),
        (.media,   [.photo, .signature]),
        (.data,    [.location])
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(grouped, id: \.0.rawValue) { category, types in
                    Section(category.rawValue) {
                        ForEach(types, id: \.self) { type in
                            Button {
                                let field = FormField(label: "", type: type, sortOrder: 0)
                                onSelect(field)
                                dismiss()
                            } label: {
                                HStack(spacing: 14) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(type.isLayoutOnly ? Color.orange.opacity(0.12) : Color.blue.opacity(0.12))
                                            .frame(width: 38, height: 38)
                                        Image(systemName: type.icon)
                                            .foregroundColor(type.isLayoutOnly ? .orange : .blue)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(type.displayName)
                                            .font(.subheadline)
                                            .foregroundColor(.primary)
                                        Text(type.shortDescription)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Add Field")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private extension FormFieldType {
    var shortDescription: String {
        switch self {
        case .sectionHeader:    return "Bold heading to group fields"
        case .instructions:     return "Read-only text block"
        case .shortText, .text: return "Single line text input"
        case .longText:         return "Multi-line paragraph"
        case .number:           return "Numeric value with optional unit"
        case .date:             return "Date picker"
        case .time:             return "Time picker"
        case .dateTime:         return "Date and time picker"
        case .yesNo:            return "Yes or No toggle"
        case .yesNoNA:          return "Yes, No, or N/A"
        case .passFail:         return "Pass or Fail toggle"
        case .passFailNA:       return "Pass, Fail, or N/A"
        case .singleChoice:     return "Pick one from a list"
        case .multipleChoice:   return "Pick multiple from a list"
        case .dropdown:         return "Single selection from a menu"
        case .rating:           return "Star or number rating"
        case .slider:           return "Value on a continuous scale"
        case .photo:            return "Camera or photo library"
        case .signature:        return "Finger-draw signature"
        case .scan:             return "Scan physical document + OCR"
        case .location:         return "Capture GPS coordinates"
        }
    }
}

// MARK: - Field Editor Sheet

struct FieldEditorSheet: View {
    let field: FormField
    let onSave: (FormField) -> Void
    @Environment(\.dismiss) var dismiss

    @State private var label: String
    @State private var hint: String
    @State private var isRequired: Bool
    @State private var columnWidth: ColumnWidth
    @State private var autoVariable: AutoVariable?
    @State private var permission: FieldPermission
    @State private var options: [String]
    @State private var unit: String
    @State private var ratingMax: Int
    @State private var sliderMin: Double
    @State private var sliderMax: Double
    @State private var sliderStep: Double
    @State private var sliderMinLabel: String
    @State private var sliderMaxLabel: String
    @State private var bodyText: String
    @State private var newOptionText = ""

    init(field: FormField, onSave: @escaping (FormField) -> Void) {
        self.field = field
        self.onSave = onSave
        _label          = State(initialValue: field.label)
        _hint           = State(initialValue: field.hint ?? "")
        _isRequired     = State(initialValue: field.isRequired)
        _columnWidth    = State(initialValue: field.columnWidth)
        _autoVariable   = State(initialValue: field.autoVariable)
        _permission     = State(initialValue: field.permission)
        _options        = State(initialValue: field.options ?? [])
        _unit           = State(initialValue: field.unit ?? "")
        _ratingMax      = State(initialValue: field.ratingMax)
        _sliderMin      = State(initialValue: field.sliderMin)
        _sliderMax      = State(initialValue: field.sliderMax)
        _sliderStep     = State(initialValue: field.sliderStep)
        _sliderMinLabel = State(initialValue: field.sliderMinLabel ?? "")
        _sliderMaxLabel = State(initialValue: field.sliderMaxLabel ?? "")
        _bodyText       = State(initialValue: field.bodyText ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                // Field type badge (read-only)
                Section {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(field.type.isLayoutOnly ? Color.orange.opacity(0.15) : Color.blue.opacity(0.15))
                                .frame(width: 40, height: 40)
                            Image(systemName: field.type.icon)
                                .foregroundColor(field.type.isLayoutOnly ? .orange : .blue)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.type.displayName).font(.headline)
                            Text(field.type.shortDescription).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Label / body text
                if field.type == .sectionHeader {
                    Section("Heading Text *") {
                        TextField("e.g. Site Conditions", text: $label)
                    }
                } else if field.type == .instructions {
                    Section("Instructions Label") {
                        TextField("e.g. Read before proceeding", text: $label)
                    }
                    Section("Instructions Body *") {
                        TextEditor(text: $bodyText)
                            .frame(minHeight: 80)
                    }
                } else {
                    Section("Field Label *") {
                        TextField("e.g. Are all PPE requirements met?", text: $label)
                    }
                    Section("Helper Text (optional)") {
                        TextField("Hint shown below the label", text: $hint)
                    }
                }

                // Options for choice fields
                if [.singleChoice, .multipleChoice, .dropdown].contains(field.type) {
                    Section {
                        ForEach(options, id: \.self) { opt in
                            HStack {
                                Text(opt)
                                Spacer()
                                Button {
                                    options.removeAll { $0 == opt }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                }
                            }
                        }
                        HStack {
                            TextField("New option", text: $newOptionText)
                            Button("Add") {
                                let trimmed = newOptionText.trimmingCharacters(in: .whitespaces)
                                if !trimmed.isEmpty && !options.contains(trimmed) {
                                    options.append(trimmed)
                                    newOptionText = ""
                                }
                            }
                            .disabled(newOptionText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    } header: {
                        Text("Options (\(options.count))")
                    } footer: {
                        if options.isEmpty {
                            Text("Add at least one option.")
                                .foregroundColor(.red)
                        }
                    }
                }

                // Number unit
                if field.type == .number {
                    Section("Unit (optional)") {
                        TextField("e.g. kg, meters, °C", text: $unit)
                    }
                }

                // Rating config
                if field.type == .rating {
                    Section("Rating Scale") {
                        Picker("Maximum", selection: $ratingMax) {
                            Text("1 – 5").tag(5)
                            Text("1 – 10").tag(10)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                // Slider config
                if field.type == .slider {
                    Section("Slider Range") {
                        HStack {
                            Text("Min")
                            Spacer()
                            TextField("0", value: $sliderMin, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 60)
                        }
                        HStack {
                            Text("Max")
                            Spacer()
                            TextField("10", value: $sliderMax, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 60)
                        }
                        HStack {
                            Text("Step")
                            Spacer()
                            TextField("1", value: $sliderStep, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 60)
                        }
                        TextField("Min label (e.g. Never)", text: $sliderMinLabel)
                        TextField("Max label (e.g. Always)", text: $sliderMaxLabel)
                    }
                }

                // Required toggle (not for layout fields)
                if !field.type.isLayoutOnly {
                    Section {
                        Toggle("Required", isOn: $isRequired)
                    }
                }

                // Column width
                if !field.type.isLayoutOnly {
                    Section("Layout") {
                        Picker("Width", selection: $columnWidth) {
                            ForEach(ColumnWidth.allCases, id: \.self) { w in
                                Label(w.displayName, systemImage: w.icon).tag(w)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(columnWidth == .half
                             ? "This field shares a row with the next half-width field."
                             : "This field takes the full row.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Auto-variable (input + date fields only)
                if [.shortText, .text, .longText, .date, .time, .dateTime].contains(field.type) {
                    Section {
                        Picker("Auto-fill from", selection: $autoVariable) {
                            Text("None — user enters manually").tag(AutoVariable?.none)
                            ForEach(AutoVariable.allCases, id: \.self) { v in
                                Label(v.displayName, systemImage: v.icon).tag(AutoVariable?.some(v))
                            }
                        }
                    } header: {
                        Text("Auto-Variable")
                    } footer: {
                        if let v = autoVariable {
                            Text("Will pre-fill with \"\(v.displayName)\" when the form opens.")
                                .font(.caption)
                        }
                    }
                }

                // Edit permission
                Section("Who Can Edit") {
                    Picker("Permission", selection: $permission) {
                        ForEach(FieldPermission.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Edit Field")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { save() }
                        .bold()
                        .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty &&
                                  field.type != .instructions)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func save() {
        var updated = field
        updated.label           = label.trimmingCharacters(in: .whitespaces)
        updated.hint            = hint.isEmpty ? nil : hint
        updated.isRequired      = isRequired
        updated.columnWidth     = columnWidth
        updated.autoVariable    = autoVariable
        updated.permission      = permission
        updated.options         = options.isEmpty ? nil : options
        updated.unit            = unit.isEmpty ? nil : unit
        updated.ratingMax       = ratingMax
        updated.sliderMin       = sliderMin
        updated.sliderMax       = sliderMax
        updated.sliderStep      = sliderStep
        updated.sliderMinLabel  = sliderMinLabel.isEmpty ? nil : sliderMinLabel
        updated.sliderMaxLabel  = sliderMaxLabel.isEmpty ? nil : sliderMaxLabel
        updated.bodyText        = bodyText.isEmpty ? nil : bodyText
        onSave(updated)
        dismiss()
    }
}

// MARK: - Field Assigner Sheet (assign fields into a group)

struct FieldAssignerSheet: View {
    let groupID: UUID
    let allFields: [FormField]
    @Binding var groups: [FieldGroup]
    @Environment(\.dismiss) var dismiss

    private var group: FieldGroup? { groups.first { $0.id == groupID } }
    private var assignedIDs: Set<UUID> { Set(group?.fieldIDs ?? []) }

    // Fields already assigned to OTHER groups
    private var takenIDs: Set<UUID> {
        Set(groups.filter { $0.id != groupID }.flatMap { $0.fieldIDs })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Select fields to include in \"\(group?.name ?? "this group")\". Fields already in another group are shown greyed out.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Available Fields") {
                    ForEach(allFields) { field in
                        let isAssigned = assignedIDs.contains(field.id)
                        let isTaken   = takenIDs.contains(field.id)

                        Button {
                            guard !isTaken else { return }
                            if let gIdx = groups.firstIndex(where: { $0.id == groupID }) {
                                if isAssigned {
                                    groups[gIdx].fieldIDs.removeAll { $0 == field.id }
                                } else {
                                    groups[gIdx].fieldIDs.append(field.id)
                                }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: isAssigned ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(isAssigned ? .blue : .secondary)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(field.label.isEmpty ? "(untitled \(field.type.displayName))" : field.label)
                                        .font(.subheadline)
                                        .foregroundColor(isTaken && !isAssigned ? .secondary : .primary)
                                    Text(field.type.displayName)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                if isTaken && !isAssigned {
                                    Text("In another group")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .disabled(isTaken && !isAssigned)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Assign Fields")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.bold()
                }
            }
        }
    }
}

// MARK: - FormFieldType CaseIterable (kept for compatibility)
extension FormFieldType {
    static var inputCases: [FormFieldType] {
        [.shortText, .longText, .number, .date, .time, .dateTime,
         .yesNo, .yesNoNA, .passFail, .passFailNA,
         .singleChoice, .multipleChoice, .dropdown,
         .rating, .slider, .photo, .signature, .location,
         .sectionHeader, .instructions]
    }
}
