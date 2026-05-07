import SwiftUI

struct SafetyView: View {
    var store: AppStore
    @State private var selectedSection = 0
    let sections = ["Dashboard", "Forms", "Orientations", "Documents", "Certificates", "Actions"]

    var forms: [SafetyForm] { store.safetyForms }
    var orientations: [WorkerOrientation] { store.orientations }
    var documents: [SafetyDocument] { store.safetyDocuments }
    var certificates: [SafetyCertificate] { store.certificates }
    var allActions: [SafetyAction] { store.safetyForms.flatMap { $0.actions } }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(sections.indices, id: \.self) { idx in
                            Button(action: { selectedSection = idx }) {
                                Text(sections[idx]).font(.subheadline)
                                    .fontWeight(selectedSection == idx ? .semibold : .regular)
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(selectedSection == idx ? Color.blue : Color(.systemGray5))
                                    .foregroundColor(selectedSection == idx ? .white : .primary)
                                    .cornerRadius(20)
                            }
                        }
                    }
                    .padding(.horizontal).padding(.vertical, 8)
                }
                .background(Color(.systemGray6))

                Group {
                    switch selectedSection {
                    case 0: SafetyDashboard(forms: forms, orientations: orientations, certificates: certificates, actions: allActions)
                    case 1: SafetyFormsSection(store: store)
                    case 2: SafetyOrientationsSection(store: store)
                    case 3: SafetyDocumentsSection(store: store)
                    case 4: SafetyCertificatesSection(store: store)
                    case 5: SafetyActionsSection(actions: allActions)
                    default: EmptyView()
                    }
                }
            }
            .navigationTitle("Safety")
        }
    }
}

struct SafetyDashboard: View {
    let forms: [SafetyForm]
    let orientations: [WorkerOrientation]
    let certificates: [SafetyCertificate]
    let actions: [SafetyAction]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    SchedStatCard("Total Forms", "\(forms.count)", "doc.fill", .blue)
                    SchedStatCard("Open Actions", "\(actions.filter { !$0.completed }.count)", "flag.fill", .red)
                    SchedStatCard("Orientations", "\(orientations.count)", "person.badge.plus", .green)
                    SchedStatCard("Expiring Certs", "\(certificates.filter { $0.isExpiringSoon || $0.isExpired }.count)", "exclamationmark.circle.fill", .orange)
                }
                .padding(.horizontal)

                if !forms.filter({ $0.status == .requiresAction }).isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Requires Action").font(.headline).padding(.horizontal)
                        ForEach(forms.filter { $0.status == .requiresAction }) { form in
                            HStack {
                                Image(systemName: form.type.icon).foregroundColor(form.type.color)
                                VStack(alignment: .leading) {
                                    Text(form.title).font(.subheadline).fontWeight(.semibold)
                                    Text(form.site).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                SafetyStatusPill(status: form.status)
                            }
                            .padding().background(Color(.systemGray6)).cornerRadius(10).padding(.horizontal)
                        }
                    }
                }

                if !certificates.filter({ $0.isExpiringSoon || $0.isExpired }).isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Certificate Alerts").font(.headline).padding(.horizontal)
                        ForEach(certificates.filter { $0.isExpiringSoon || $0.isExpired }) { cert in
                            HStack {
                                Image(systemName: "exclamationmark.circle.fill").foregroundColor(cert.isExpired ? .red : .orange)
                                VStack(alignment: .leading) {
                                    Text(cert.workerName).font(.subheadline).fontWeight(.semibold)
                                    Text(cert.certificateType).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(cert.isExpired ? "Expired" : "Expiring Soon").font(.caption).foregroundColor(cert.isExpired ? .red : .orange)
                            }
                            .padding().background(Color(.systemGray6)).cornerRadius(10).padding(.horizontal)
                        }
                    }
                }
                Spacer(minLength: 20)
            }
            .padding(.top)
        }
    }
}

struct SafetyFormsSection: View {
    var store: AppStore
    @State private var showAdd = false
    @State private var filterType: SafetyFormType? = nil

    var filtered: [SafetyForm] {
        guard let t = filterType else { return store.safetyForms }
        return store.safetyForms.filter { $0.type == t }
    }

    var body: some View {
        VStack {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    SafetyFilterChip("All", filterType == nil) { filterType = nil }
                    ForEach(SafetyFormType.allCases, id: \.self) { t in
                        SafetyFilterChip(t.rawValue, filterType == t) { filterType = t }
                    }
                }
                .padding(.horizontal).padding(.vertical, 6)
            }
            if filtered.isEmpty {
                Spacer(); Text("No forms yet").foregroundColor(.secondary); Spacer()
            } else {
                List {
                    ForEach(filtered) { form in
                        NavigationLink(destination: SafetyFormDetail(form: form, store: store)) {
                            HStack(spacing: 12) {
                                Image(systemName: form.type.icon).foregroundColor(form.type.color).frame(width: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(form.title).font(.subheadline).fontWeight(.semibold)
                                    Text(form.site).font(.caption).foregroundColor(.secondary)
                                    Text(form.date, style: .date).font(.caption2).foregroundColor(.secondary)
                                }
                                Spacer()
                                SafetyStatusPill(status: form.status)
                            }.padding(.vertical, 4)
                        }
                    }
                    .onDelete { store.deleteSafetyForm(at: $0) }
                }
            }
        }
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { showAdd = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $showAdd) { AddSafetyFormView(store: store) }
    }
}

struct SafetyFormDetail: View {
    var form: SafetyForm
    var store: AppStore
    @State private var localForm: SafetyForm
    @State private var showAddAction = false
    @State private var signerName = ""

    init(form: SafetyForm, store: AppStore) { self.form = form; self.store = store; _localForm = State(initialValue: form) }

    var body: some View {
        Form {
            Section("Form Details") {
                LabeledContent("Type", value: localForm.type.rawValue)
                LabeledContent("Site", value: localForm.site)
                LabeledContent("Assigned To", value: localForm.assignedTo)
                LabeledContent("Date", value: localForm.date, format: .dateTime.day().month().year())
            }
            Section("Status") {
                Picker("Status", selection: $localForm.status) {
                    ForEach(SafetyStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: localForm.status) { _, _ in store.updateSafetyForm(localForm) }
            }
            Section("Notes") { TextField("Notes", text: $localForm.notes, axis: .vertical).lineLimit(4) }
            Section("Actions (\(localForm.actions.filter { !$0.completed }.count) open)") {
                ForEach($localForm.actions) { $action in
                    HStack {
                        Image(systemName: action.completed ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(action.completed ? .green : .secondary)
                            .onTapGesture { action.completed.toggle(); store.updateSafetyForm(localForm) }
                        VStack(alignment: .leading) {
                            Text(action.description).font(.subheadline)
                            Text("Assigned: \(action.assignedTo)").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                Button { showAddAction = true } label: { Label("Add Action", systemImage: "plus.circle") }
            }
            Section("Signatures (\(localForm.signatures.count))") {
                ForEach(localForm.signatures, id: \.self) { Label($0, systemImage: "signature") }
                HStack {
                    TextField("Name", text: $signerName)
                    Button("Add") { if !signerName.isEmpty { localForm.signatures.append(signerName); signerName = ""; store.updateSafetyForm(localForm) } }.disabled(signerName.isEmpty)
                }
            }
        }
        .navigationTitle(localForm.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddAction) { SafetyAddActionView(actions: $localForm.actions, onSave: { store.updateSafetyForm(localForm) }) }
    }
}

struct AddSafetyFormView: View {
    var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var title = ""; @State private var type = SafetyFormType.toolboxTalk
    @State private var site = ""; @State private var assignedTo = ""; @State private var notes = ""; @State private var date = Date()

    var body: some View {
        NavigationView {
            Form {
                Section("Form Info") {
                    TextField("Title", text: $title)
                    Picker("Type", selection: $type) { ForEach(SafetyFormType.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Picker("Site / Project", selection: $site) {
                        Text("Select Site").tag("")
                        ForEach(store.activeProjectNames, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Assigned To", text: $assignedTo)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }
                Section("Notes") { TextField("Notes", text: $notes, axis: .vertical).lineLimit(3) }
            }
            .navigationTitle("New Safety Form")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        store.addSafetyForm(SafetyForm(type: type, title: title, site: site, assignedTo: assignedTo, date: date, status: .open, notes: notes))
                        dismiss()
                    }.disabled(title.isEmpty || site.isEmpty)
                }
            }
        }
    }
}

struct SafetyOrientationsSection: View {
    var store: AppStore
    @State private var showAdd = false

    var body: some View {
        VStack {
            if store.orientations.isEmpty {
                Spacer(); Text("No orientations yet").foregroundColor(.secondary); Spacer()
            } else {
                List {
                    ForEach(store.orientations) { o in
                        HStack {
                            Image(systemName: o.completed ? "checkmark.circle.fill" : "circle").foregroundColor(o.completed ? .green : .secondary)
                            VStack(alignment: .leading) {
                                Text(o.workerName).font(.subheadline).fontWeight(.semibold)
                                Text("\(o.company) · \(o.site)").font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("\(o.modules.filter { $0.completed }.count)/\(o.modules.count)").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .onDelete { store.deleteOrientation(at: $0) }
                }
            }
        }
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { showAdd = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $showAdd) { AddOrientationView(store: store) }
    }
}

struct AddOrientationView: View {
    var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var workerName = ""; @State private var company = "Blair Ventures"; @State private var site = ""; @State private var date = Date()
    let companies = ["Blair Ventures", "Integral Containment Systems"]
    let defaultModules = ["Site Safety Rules", "Emergency Procedures", "PPE Requirements", "Hazard Communication", "Incident Reporting"]

    var body: some View {
        NavigationView {
            Form {
                Section("Worker Info") {
                    TextField("Worker Name", text: $workerName)
                    Picker("Company", selection: $company) { ForEach(companies, id: \.self) { Text($0) } }
                    Picker("Site", selection: $site) {
                        Text("Select Site").tag("")
                        ForEach(store.activeProjectNames, id: \.self) { Text($0).tag($0) }
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }
            }
            .navigationTitle("New Orientation")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        let modules = defaultModules.map { OrientationModule(title: $0) }
                        store.addOrientation(WorkerOrientation(workerName: workerName, company: company, site: site, date: date, modules: modules))
                        dismiss()
                    }.disabled(workerName.isEmpty || site.isEmpty)
                }
            }
        }
    }
}

struct SafetyDocumentsSection: View {
    var store: AppStore
    @State private var showAdd = false
    var grouped: [String: [SafetyDocument]] { Dictionary(grouping: store.safetyDocuments) { $0.category } }

    var body: some View {
        VStack {
            if store.safetyDocuments.isEmpty {
                Spacer(); Text("No documents yet").foregroundColor(.secondary); Spacer()
            } else {
                List {
                    ForEach(grouped.keys.sorted(), id: \.self) { cat in
                        Section(cat) {
                            ForEach(grouped[cat] ?? []) { doc in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(doc.title).font(.subheadline).fontWeight(.semibold)
                                    Text(doc.dateAdded, style: .date).font(.caption).foregroundColor(.secondary)
                                    if !doc.notes.isEmpty { Text(doc.notes).font(.caption2).foregroundColor(.secondary) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { showAdd = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $showAdd) { AddDocumentView(store: store) }
    }
}

struct AddDocumentView: View {
    var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var title = ""; @State private var category = "Policy"; @State private var notes = ""
    let categories = ["Policy", "Procedure", "MSDS / SDS", "Training", "Permit", "Other"]

    var body: some View {
        NavigationView {
            Form {
                TextField("Document Title", text: $title)
                Picker("Category", selection: $category) { ForEach(categories, id: \.self) { Text($0) } }
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(3)
            }
            .navigationTitle("Add Document")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { store.addDocument(SafetyDocument(title: title, category: category, dateAdded: Date(), notes: notes)); dismiss() }.disabled(title.isEmpty)
                }
            }
        }
    }
}

struct SafetyCertificatesSection: View {
    var store: AppStore
    @State private var showAdd = false

    var body: some View {
        VStack {
            if store.certificates.isEmpty {
                Spacer(); Text("No certificates yet").foregroundColor(.secondary); Spacer()
            } else {
                List {
                    ForEach(store.certificates) { cert in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cert.workerName).font(.subheadline).fontWeight(.semibold)
                                Text(cert.certificateType).font(.caption).foregroundColor(.secondary)
                                Text(cert.company).font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                if cert.isExpired { Label("Expired", systemImage: "xmark.circle.fill").font(.caption).foregroundColor(.red) }
                                else if cert.isExpiringSoon { Label("Expiring Soon", systemImage: "exclamationmark.circle.fill").font(.caption).foregroundColor(.orange) }
                                else { Label("Valid", systemImage: "checkmark.circle.fill").font(.caption).foregroundColor(.green) }
                                Text("Exp: \(cert.expiryDate, style: .date)").font(.caption2).foregroundColor(.secondary)
                            }
                        }.padding(.vertical, 4)
                    }
                    .onDelete { store.deleteCertificate(at: $0) }
                }
            }
        }
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { showAdd = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $showAdd) { AddCertificateView(store: store) }
    }
}

struct AddCertificateView: View {
    var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var workerName = ""; @State private var certType = "First Aid"; @State private var company = "Blair Ventures"
    @State private var issueDate = Date(); @State private var expiryDate = Date().addingTimeInterval(365 * 24 * 3600)
    let companies = ["Blair Ventures", "Integral Containment Systems"]
    let certTypes = ["First Aid", "H2S Alive", "Fall Protection", "WHMIS", "Confined Space", "Forklift", "Other"]

    var body: some View {
        NavigationView {
            Form {
                Section("Worker") {
                    TextField("Worker Name", text: $workerName)
                    Picker("Company", selection: $company) { ForEach(companies, id: \.self) { Text($0) } }
                }
                Section("Certificate") {
                    Picker("Type", selection: $certType) { ForEach(certTypes, id: \.self) { Text($0).tag($0) } }
                    DatePicker("Issue Date", selection: $issueDate, displayedComponents: .date)
                    DatePicker("Expiry Date", selection: $expiryDate, displayedComponents: .date)
                }
            }
            .navigationTitle("Add Certificate")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { store.addCertificate(SafetyCertificate(workerName: workerName, certificateType: certType, issueDate: issueDate, expiryDate: expiryDate, company: company)); dismiss() }.disabled(workerName.isEmpty)
                }
            }
        }
    }
}

struct SafetyActionsSection: View {
    let actions: [SafetyAction]
    var body: some View {
        Group {
            if actions.isEmpty {
                VStack { Spacer(); Text("No actions yet").foregroundColor(.secondary); Text("Actions are created from within safety forms").font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).padding(); Spacer() }
            } else {
                List {
                    Section("Open") {
                        ForEach(actions.filter { !$0.completed }) { SafetyActionRow(action: $0) }
                    }
                    Section("Completed") {
                        ForEach(actions.filter { $0.completed }) { SafetyActionRow(action: $0) }
                    }
                }
            }
        }
    }
}

struct SafetyActionRow: View {
    let action: SafetyAction
    var body: some View {
        HStack {
            Image(systemName: action.completed ? "checkmark.circle.fill" : "circle").foregroundColor(action.completed ? .green : .secondary)
            VStack(alignment: .leading) {
                Text(action.description).font(.subheadline)
                Text("Assigned: \(action.assignedTo)").font(.caption).foregroundColor(.secondary)
                Text(action.dueDate, style: .date).font(.caption2).foregroundColor(action.dueDate < Date() && !action.completed ? .red : .secondary)
            }
        }
    }
}

struct SafetyAddActionView: View {
    @Binding var actions: [SafetyAction]
    var onSave: () -> Void
    @Environment(\.dismiss) var dismiss
    @State private var description = ""; @State private var assignedTo = ""; @State private var dueDate = Date().addingTimeInterval(7 * 24 * 3600)

    var body: some View {
        NavigationView {
            Form {
                TextField("Describe the action required", text: $description, axis: .vertical).lineLimit(3)
                TextField("Assigned To", text: $assignedTo)
                DatePicker("Due Date", selection: $dueDate, displayedComponents: .date)
            }
            .navigationTitle("Add Action")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { actions.append(SafetyAction(description: description, assignedTo: assignedTo, dueDate: dueDate)); onSave(); dismiss() }.disabled(description.isEmpty || assignedTo.isEmpty)
                }
            }
        }
    }
}

struct SafetyStatusPill: View {
    let status: SafetyStatus
    var body: some View {
        Text(status.rawValue).font(.caption2).fontWeight(.semibold)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(status.color.opacity(0.15)).foregroundColor(status.color).cornerRadius(8)
    }
}

struct SafetyFilterChip: View {
    let label: String; let selected: Bool; let action: () -> Void
    init(_ label: String, _ selected: Bool, _ action: @escaping () -> Void) { self.label = label; self.selected = selected; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(label).font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Color.blue : Color(.systemGray5))
                .foregroundColor(selected ? .white : .primary).cornerRadius(16)
        }
    }
}
