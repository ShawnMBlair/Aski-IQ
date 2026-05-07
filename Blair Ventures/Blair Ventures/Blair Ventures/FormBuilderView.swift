import SwiftUI

// MARK: - Models

enum FormFieldType: String, CaseIterable {
    case text = "Text"
    case number = "Number"
    case yesNo = "Yes / No"
    case multipleChoice = "Multiple Choice"
    case dropdown = "Dropdown"
    case checkboxGroup = "Checkbox Group"
    case signature = "Signature"
    case date = "Date"
    case photo = "Photo"
    case instruction = "Instruction"
    case rating = "Rating Scale"

    var icon: String {
        switch self {
        case .text: return "text.cursor"
        case .number: return "number"
        case .yesNo: return "checkmark.circle"
        case .multipleChoice: return "list.bullet.circle"
        case .dropdown: return "chevron.down.circle"
        case .checkboxGroup: return "checkmark.square"
        case .signature: return "signature"
        case .date: return "calendar"
        case .photo: return "camera"
        case .instruction: return "info.circle"
        case .rating: return "star.circle"
        }
    }
}

enum FormTemplateType: String, CaseIterable {
    case toolboxTalk = "Toolbox Talk"
    case hazardAssessment = "Hazard Assessment"
    case incidentReport = "Incident Report"
    case inspection = "Inspection"
    case jsa = "Job Safety Analysis"
    case custom = "Custom"
}

struct FormField: Identifiable {
    let id = UUID()
    var label: String
    var type: FormFieldType
    var required: Bool = false
    var options: [String] = []
    var placeholder: String = ""
    var instructions: String = ""
}

struct FormGroup: Identifiable {
    let id = UUID()
    var title: String
    var fields: [FormField] = []
}

struct FormTemplate: Identifiable {
    let id = UUID()
    var title: String
    var templateType: FormTemplateType
    var company: String
    var published: Bool = true
    var groups: [FormGroup] = []
    var createdDate: Date = Date()
}

struct SubmittedForm: Identifiable {
    let id = UUID()
    var templateID: UUID
    var templateTitle: String
    var site: String
    var company: String
    var submittedBy: String
    var submittedDate: Date
    var responses: [UUID: String]
}

// MARK: - Form Builder Main View

struct FormBuilderView: View {
    @State private var templates: [FormTemplate] = []
    @State private var submissions: [SubmittedForm] = []
    @State private var showingBuilder = false
    @State private var selectedTemplate: FormTemplate? = nil
    @State private var showingFillForm = false
    @State private var formToFill: FormTemplate? = nil

    var body: some View {
        NavigationView {
            Group {
                if templates.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 60))
                            .foregroundColor(.blue.opacity(0.6))
                        Text("No Form Templates")
                            .font(.title2).fontWeight(.semibold)
                        Text("Create reusable form templates for your team")
                            .font(.subheadline).foregroundColor(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal)
                        Button(action: { showingBuilder = true }) {
                            Label("Create Form Template", systemImage: "plus.circle.fill")
                                .padding().background(Color.blue).foregroundColor(.white).cornerRadius(12)
                        }
                        Spacer()
                    }
                } else {
                    List {
                        Section("Templates (\(templates.count))") {
                            ForEach($templates) { $template in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(template.title).font(.subheadline).fontWeight(.semibold)
                                            if template.published {
                                                Text("Published").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                                    .background(Color.green.opacity(0.15)).foregroundColor(.green).cornerRadius(6)
                                            }
                                        }
                                        Text(template.templateType.rawValue).font(.caption).foregroundColor(.secondary)
                                        Text("\(template.groups.count) groups · \(template.groups.flatMap { $0.fields }.count) fields")
                                            .font(.caption2).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Menu {
                                        Button(action: {
                                            formToFill = template
                                            showingFillForm = true
                                        }) { Label("Fill Out", systemImage: "square.and.pencil") }
                                        Button(action: {
                                            selectedTemplate = template
                                            showingBuilder = true
                                        }) { Label("Edit Template", systemImage: "pencil") }
                                    } label: {
                                        Image(systemName: "ellipsis.circle").foregroundColor(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .onDelete { templates.remove(atOffsets: $0) }
                        }

                        if !submissions.isEmpty {
                            Section("Recent Submissions (\(submissions.count))") {
                                ForEach(submissions) { sub in
                                    NavigationLink(destination: SubmissionDetailView(submission: sub, templates: templates)) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(sub.templateTitle).font(.subheadline).fontWeight(.semibold)
                                            Text("\(sub.site) · \(sub.submittedBy)").font(.caption).foregroundColor(.secondary)
                                            Text(sub.submittedDate, style: .date).font(.caption2).foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Form Builder")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        selectedTemplate = nil
                        showingBuilder = true
                    }) { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingBuilder) {
                FormEditorView(templates: $templates, editingTemplate: selectedTemplate)
            }
            .sheet(isPresented: $showingFillForm) {
                if let template = formToFill {
                    FillFormView(template: template, submissions: $submissions)
                }
            }
        }
    }
}

// MARK: - Form Editor

struct FormEditorView: View {
    @Binding var templates: [FormTemplate]
    var editingTemplate: FormTemplate?
    @Environment(\.dismiss) var dismiss

    @State private var selectedTab = 0
    @State private var title = ""
    @State private var templateType = FormTemplateType.custom
    @State private var company = "Blair Ventures"
    @State private var published = true
    @State private var groups: [FormGroup] = [FormGroup(title: "New Group")]
    @State private var showingAddField: FormGroup? = nil
    @State private var showingPreview = false

    let companies = ["Blair Ventures", "Integral Containment Systems"]
    let tabs = ["Editor", "Options", "Preview"]

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Tab Bar
                HStack(spacing: 0) {
                    ForEach(tabs.indices, id: \.self) { idx in
                        Button(action: { selectedTab = idx }) {
                            VStack(spacing: 4) {
                                Text(tabs[idx])
                                    .font(.subheadline)
                                    .fontWeight(selectedTab == idx ? .semibold : .regular)
                                    .foregroundColor(selectedTab == idx ? .blue : .secondary)
                                Rectangle()
                                    .fill(selectedTab == idx ? Color.blue : Color.clear)
                                    .frame(height: 2)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.top, 8)
                .background(Color(.systemBackground))

                Divider()

                switch selectedTab {
                case 0: editorTab
                case 1: optionsTab
                case 2: previewTab
                default: EmptyView()
                }
            }
            .navigationTitle(title.isEmpty ? "New Template" : title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { loadExisting() }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save Template") { saveTemplate() }
                        .fontWeight(.semibold)
                        .disabled(title.isEmpty)
                }
            }
        }
    }

    // MARK: Editor Tab
    var editorTab: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    Text("Form Template Structure")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.top)

                    ForEach($groups) { $group in
                        GroupEditorCard(group: $group, onAddField: {
                            showingAddField = group
                        }, onDelete: {
                            groups.removeAll { $0.id == group.id }
                        })
                        .padding(.horizontal)
                    }

                    Button(action: {
                        groups.append(FormGroup(title: "New Group"))
                    }) {
                        HStack {
                            Image(systemName: "plus.circle.fill").foregroundColor(.blue)
                            Text("New Group +").foregroundColor(.blue).fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue, style: StrokeStyle(dash: [6])))
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                }
            }

            Divider()

            // Right Panel
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Information").font(.headline)

                    TextField("Form Template Title", text: $title)
                        .textFieldStyle(.roundedBorder)

                    Picker("Type", selection: $templateType) {
                        ForEach(FormTemplateType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)

                    Toggle("Published", isOn: $published)

                    Divider()

                    Text("Company").font(.headline)
                    Picker("Company", selection: $company) {
                        ForEach(companies, id: \.self) { Text($0) }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                }
                .padding()
            }
            .frame(width: 200)
        }
        .sheet(isPresented: Binding(
            get: { showingAddField != nil },
            set: { if !$0 { showingAddField = nil } }
        )) {
            if let idx = groups.firstIndex(where: { $0.id == showingAddField?.id }) {
                AddFieldView(fields: $groups[idx].fields)
            }
        }
    }

    // MARK: Options Tab
    var optionsTab: some View {
        VStack {
            HStack {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Key").frame(width: 80, alignment: .leading)
                Text("Type").frame(width: 100, alignment: .leading)
            }
            .font(.caption).fontWeight(.semibold)
            .foregroundColor(.secondary)
            .padding(.horizontal).padding(.top)

            Divider()

            let allFields = groups.flatMap { $0.fields }
            if allFields.isEmpty {
                Spacer()
                Text("Add fields in the Editor tab").foregroundColor(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(allFields) { field in
                        HStack {
                            Text(field.label).frame(maxWidth: .infinity, alignment: .leading).font(.subheadline)
                            Text(field.label.lowercased().replacingOccurrences(of: " ", with: "_"))
                                .frame(width: 80, alignment: .leading).font(.caption).foregroundColor(.secondary)
                            Text(field.type.rawValue)
                                .frame(width: 100, alignment: .leading).font(.caption).foregroundColor(.blue)
                        }
                    }
                }
            }
        }
    }

    // MARK: Preview Tab
    var previewTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text(company.uppercased())
                        .font(.title2).fontWeight(.heavy)
                        .foregroundColor(.primary)

                    Text(title.isEmpty ? "Form Preview" : title)
                        .font(.title).fontWeight(.bold)

                    HStack {
                        Image(systemName: "calendar").foregroundColor(.blue)
                        VStack(alignment: .leading) {
                            Text("Created Date:").font(.caption).foregroundColor(.secondary)
                            Text(Date(), style: .date).font(.subheadline).fontWeight(.semibold)
                        }
                    }

                    HStack {
                        Image(systemName: "mappin.circle").foregroundColor(.blue)
                        Text("Site:").font(.caption).foregroundColor(.secondary)
                        Text("Form Preview Project").font(.subheadline).fontWeight(.semibold)
                    }

                    HStack {
                        Image(systemName: "building.2").foregroundColor(.blue)
                        Text("Company:").font(.caption).foregroundColor(.secondary)
                        Text(company).font(.subheadline).fontWeight(.semibold)
                    }
                }
                .padding()
                .background(Color(.systemBackground))

                Divider()

                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(group.title)
                            .font(.headline).fontWeight(.semibold)
                            .foregroundColor(.blue)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(Color.blue.opacity(0.07))

                        Divider()

                        ForEach(group.fields) { field in
                            FormFieldPreviewRow(field: field)
                            Divider()
                        }

                        if group.fields.isEmpty {
                            Text("No fields added").font(.caption).foregroundColor(.secondary).padding()
                        }
                    }
                    .background(Color(.systemBackground))
                    .cornerRadius(8)
                    .padding(.horizontal).padding(.top, 8)
                }
                .padding(.bottom)
            }
        }
        .background(Color(.systemGray6))
    }

    func loadExisting() {
        guard let t = editingTemplate else { return }
        title = t.title
        templateType = t.templateType
        company = t.company
        published = t.published
        groups = t.groups
    }

    func saveTemplate() {
        let template = FormTemplate(
            title: title,
            templateType: templateType,
            company: company,
            published: published,
            groups: groups
        )
        if let idx = templates.firstIndex(where: { $0.id == editingTemplate?.id }) {
            templates[idx] = template
        } else {
            templates.append(template)
        }
        dismiss()
    }
}

// MARK: - Group Editor Card

struct GroupEditorCard: View {
    @Binding var group: FormGroup
    let onAddField: () -> Void
    let onDelete: () -> Void
    @State private var editingTitle = false
    @State private var newTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if editingTitle {
                    TextField("Group Name", text: $newTitle, onCommit: {
                        group.title = newTitle
                        editingTitle = false
                    })
                    .textFieldStyle(.roundedBorder)
                } else {
                    Text(group.title).font(.subheadline).fontWeight(.semibold)
                }
                Spacer()
                Button(action: {
                    newTitle = group.title
                    editingTitle.toggle()
                }) { Image(systemName: "pencil").foregroundColor(.secondary) }
                Button(action: onDelete) {
                    Image(systemName: "trash").foregroundColor(.red.opacity(0.7))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(.systemGray5))
            .cornerRadius(8)

            ForEach($group.fields) { $field in
                FieldEditorRow(field: $field, onDelete: {
                    group.fields.removeAll { $0.id == field.id }
                })
            }

            Button(action: onAddField) {
                HStack {
                    Image(systemName: "plus").foregroundColor(.blue)
                    Text("New Field +").foregroundColor(.blue)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue, style: StrokeStyle(dash: [5])))
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

// MARK: - Field Editor Row

struct FieldEditorRow: View {
    @Binding var field: FormField
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: field.type.icon).foregroundColor(.blue).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(field.label).font(.subheadline)
                Text(field.type.rawValue).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if field.required {
                Text("Required").font(.caption2).foregroundColor(.red)
            }
            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill").foregroundColor(.red.opacity(0.7))
            }
        }
        .padding(10)
        .background(Color(.systemBackground))
        .cornerRadius(8)
    }
}

// MARK: - Add Field View

struct AddFieldView: View {
    @Binding var fields: [FormField]
    @Environment(\.dismiss) var dismiss
    @State private var label = ""
    @State private var type = FormFieldType.text
    @State private var required = false
    @State private var optionsText = ""
    @State private var placeholder = ""
    @State private var instructions = ""

    var body: some View {
        NavigationView {
            Form {
                Section("Field Info") {
                    TextField("Field Label", text: $label)
                    Picker("Field Type", selection: $type) {
                        ForEach(FormFieldType.allCases, id: \.self) {
                            Label($0.rawValue, systemImage: $0.icon).tag($0)
                        }
                    }
                    Toggle("Required", isOn: $required)
                }

                if type == .text || type == .number {
                    Section("Placeholder") {
                        TextField("Placeholder text", text: $placeholder)
                    }
                }

                if type == .instruction {
                    Section("Instruction Text") {
                        TextField("Enter instruction or note", text: $instructions, axis: .vertical).lineLimit(4)
                    }
                }

                if [.multipleChoice, .dropdown, .checkboxGroup].contains(type) {
                    Section("Options (one per line)") {
                        TextField("Option 1\nOption 2\nOption 3", text: $optionsText, axis: .vertical).lineLimit(6)
                    }
                }

                Section("Preview") {
                    FormFieldPreviewRow(field: FormField(
                        label: label.isEmpty ? "Field Label" : label,
                        type: type,
                        required: required,
                        options: optionsText.split(separator: "\n").map(String.init),
                        placeholder: placeholder,
                        instructions: instructions
                    ))
                }
            }
            .navigationTitle("Add Field")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") {
                        let opts = optionsText.split(separator: "\n").map(String.init)
                        fields.append(FormField(label: label, type: type, required: required, options: opts, placeholder: placeholder, instructions: instructions))
                        dismiss()
                    }
                    .disabled(label.isEmpty)
                }
            }
        }
    }
}

// MARK: - Field Preview Row

struct FormFieldPreviewRow: View {
    let field: FormField
    @State private var textValue = ""
    @State private var boolValue = false
    @State private var selectedOption = ""
    @State private var rating = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(field.label)
                    .font(.subheadline).fontWeight(.medium)
                if field.required {
                    Text("*").foregroundColor(.red)
                }
            }

            switch field.type {
            case .text:
                TextField(field.placeholder.isEmpty ? "Enter text" : field.placeholder, text: $textValue)
                    .textFieldStyle(.roundedBorder)
            case .number:
                TextField(field.placeholder.isEmpty ? "Enter number" : field.placeholder, text: $textValue)
                    .textFieldStyle(.roundedBorder).keyboardType(.numberPad)
            case .yesNo:
                HStack(spacing: 12) {
                    ForEach(["Yes", "No", "N/A"], id: \.self) { opt in
                        Button(action: { selectedOption = opt }) {
                            Text(opt).font(.subheadline)
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(selectedOption == opt ? Color.blue : Color(.systemGray5))
                                .foregroundColor(selectedOption == opt ? .white : .primary)
                                .cornerRadius(8)
                        }
                    }
                }
            case .multipleChoice, .checkboxGroup:
                ForEach(field.options, id: \.self) { opt in
                    HStack {
                        Image(systemName: selectedOption == opt ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selectedOption == opt ? .blue : .secondary)
                            .onTapGesture { selectedOption = opt }
                        Text(opt).font(.subheadline)
                    }
                }
            case .dropdown:
                Picker(field.label, selection: $selectedOption) {
                    Text("Select...").tag("")
                    ForEach(field.options, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            case .date:
                Text("📅 Date picker").font(.caption).foregroundColor(.secondary)
            case .signature:
                HStack {
                    Image(systemName: "signature").foregroundColor(.blue)
                    Text("Tap to sign").foregroundColor(.secondary).font(.subheadline)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray, style: StrokeStyle(dash: [4])))
            case .photo:
                HStack {
                    Image(systemName: "camera").foregroundColor(.blue)
                    Text("Tap to add photo").foregroundColor(.secondary).font(.subheadline)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray, style: StrokeStyle(dash: [4])))
            case .instruction:
                Text(field.instructions.isEmpty ? field.label : field.instructions)
                    .font(.subheadline).foregroundColor(.secondary)
                    .padding(10).background(Color.blue.opacity(0.07)).cornerRadius(8)
            case .rating:
                HStack {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: star <= rating ? "star.fill" : "star")
                            .foregroundColor(.orange)
                            .onTapGesture { rating = star }
                    }
                }
            }
        }
        .padding()
    }
}

// MARK: - Fill Form View

struct FillFormView: View {
    let template: FormTemplate
    @Binding var submissions: [SubmittedForm]
    @Environment(\.dismiss) var dismiss
    @State private var responses: [UUID: String] = [:]
    @State private var site = ""
    @State private var submittedBy = ""

    var body: some View {
        NavigationView {
            Form {
                Section("Submission Info") {
                    TextField("Site / Location", text: $site)
                    TextField("Submitted By", text: $submittedBy)
                }

                ForEach(template.groups) { group in
                    Section(group.title) {
                        ForEach(group.fields) { field in
                            FillFieldRow(field: field, response: Binding(
                                get: { responses[field.id] ?? "" },
                                set: { responses[field.id] = $0 }
                            ))
                        }
                    }
                }
            }
            .navigationTitle(template.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Submit") {
                        let sub = SubmittedForm(
                            templateID: template.id,
                            templateTitle: template.title,
                            site: site,
                            company: template.company,
                            submittedBy: submittedBy,
                            submittedDate: Date(),
                            responses: responses
                        )
                        submissions.append(sub)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(site.isEmpty || submittedBy.isEmpty)
                }
            }
        }
    }
}

struct FillFieldRow: View {
    let field: FormField
    @Binding var response: String
    @State private var rating = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(field.label).font(.subheadline)
                if field.required { Text("*").foregroundColor(.red) }
            }
            switch field.type {
            case .text:
                TextField(field.placeholder.isEmpty ? "Enter response" : field.placeholder, text: $response, axis: .vertical)
                    .lineLimit(3)
            case .number:
                TextField("Enter number", text: $response).keyboardType(.numberPad)
            case .yesNo:
                HStack(spacing: 10) {
                    ForEach(["Yes", "No", "N/A"], id: \.self) { opt in
                        Button(action: { response = opt }) {
                            Text(opt).font(.caption).padding(.horizontal, 14).padding(.vertical, 7)
                                .background(response == opt ? Color.blue : Color(.systemGray5))
                                .foregroundColor(response == opt ? .white : .primary)
                                .cornerRadius(8)
                        }
                    }
                }
            case .multipleChoice, .checkboxGroup, .dropdown:
                ForEach(field.options, id: \.self) { opt in
                    HStack {
                        Image(systemName: response == opt ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(response == opt ? .blue : .secondary)
                            .onTapGesture { response = opt }
                        Text(opt).font(.subheadline)
                    }
                }
            case .date:
                Text("Date: \(response.isEmpty ? "Not set" : response)").foregroundColor(.secondary)
            case .signature:
                HStack {
                    Image(systemName: "signature").foregroundColor(.blue)
                    Text(response.isEmpty ? "Tap to sign" : "Signed: \(response)")
                        .foregroundColor(response.isEmpty ? .secondary : .primary)
                }
                .padding().frame(maxWidth: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray, style: StrokeStyle(dash: [4])))
                .onTapGesture { response = "Signed" }
            case .photo:
                HStack {
                    Image(systemName: "camera").foregroundColor(.blue)
                    Text(response.isEmpty ? "Tap to add photo" : "Photo added")
                        .foregroundColor(response.isEmpty ? .secondary : .green)
                }
                .padding().frame(maxWidth: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray, style: StrokeStyle(dash: [4])))
                .onTapGesture { response = "Photo" }
            case .instruction:
                Text(field.instructions.isEmpty ? field.label : field.instructions)
                    .font(.caption).foregroundColor(.secondary)
                    .padding(8).background(Color.blue.opacity(0.07)).cornerRadius(8)
            case .rating:
                HStack {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: star <= (Int(response) ?? 0) ? "star.fill" : "star")
                            .foregroundColor(.orange).onTapGesture { response = "\(star)" }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Submission Detail

struct SubmissionDetailView: View {
    let submission: SubmittedForm
    let templates: [FormTemplate]

    var template: FormTemplate? {
        templates.first { $0.id == submission.templateID }
    }

    var body: some View {
        Form {
            Section("Submission Info") {
                LabeledContent("Site", value: submission.site)
                LabeledContent("Company", value: submission.company)
                LabeledContent("Submitted By", value: submission.submittedBy)
                LabeledContent("Date", value: submission.submittedDate, format: .dateTime.day().month().year())
            }
            if let t = template {
                ForEach(t.groups) { group in
                    Section(group.title) {
                        ForEach(group.fields) { field in
                            let response = submission.responses[field.id] ?? "—"
                            LabeledContent(field.label, value: response)
                        }
                    }
                }
            }
        }
        .navigationTitle(submission.templateTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}
