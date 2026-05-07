// ProjectDocumentViews.swift
// BV APP – Project Document Storage
// Files are copied into the app's Documents directory (UUID-named).
// Metadata is persisted in UserDefaults under "bv_project_documents".

import SwiftUI
import Combine
import UniformTypeIdentifiers
import QuickLook

// MARK: - Model

enum ProjectDocumentCategory: String, Codable, CaseIterable, Identifiable {
    case contract   = "contract"
    case drawing    = "drawing"
    case permit     = "permit"
    case safety     = "safety"
    case quote      = "quote"
    case photo      = "photo"
    case report     = "report"
    case other      = "other"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .contract: return "Contract"
        case .drawing:  return "Drawing"
        case .permit:   return "Permit"
        case .safety:   return "Safety"
        case .quote:    return "Quote"
        case .photo:    return "Photo"
        case .report:   return "Report"
        case .other:    return "Other"
        }
    }

    var icon: String {
        switch self {
        case .contract: return "doc.text.fill"
        case .drawing:  return "pencil.and.ruler.fill"
        case .permit:   return "checkmark.seal.fill"
        case .safety:   return "exclamationmark.shield.fill"
        case .quote:    return "doc.richtext"
        case .photo:    return "photo.fill"
        case .report:   return "chart.bar.doc.horizontal.fill"
        case .other:    return "doc.fill"
        }
    }

    var color: Color {
        switch self {
        case .contract: return .blue
        case .drawing:  return .indigo
        case .permit:   return .green
        case .safety:   return .red
        case .quote:    return .purple
        case .photo:    return .teal
        case .report:   return .orange
        case .other:    return .gray
        }
    }
}

struct ProjectDocument: Identifiable, Codable {
    var id:               UUID   = UUID()
    var projectID:        UUID
    var name:             String                         // user-editable display name
    var originalFileName: String                         // original filename.ext
    var fileExtension:    String                         // "pdf", "jpg", "docx" …
    var fileSize:         Int                            // bytes
    var storedFileName:   String                         // UUID.ext — saved in app Documents/
    var category:         ProjectDocumentCategory = .other
    // MARK: Sample data tracking
    // Populated only by SampleDataSeeder; immutable post-insert via DB
    // trigger. Cleared along with the row when an executive runs Clear
    // Sample Data. See SampleData/SampleDataTypes.swift.
    var isSampleData:           Bool      = false
    var sampleDataBatchID:      UUID?     = nil
    var sampleDataSeedVersion:  String?   = nil
    var sampleDataCreatedAt:    Date?     = nil
    var sampleDataCreatedBy:    UUID?     = nil

    var uploadedAt:       Date   = Date()
    var uploadedBy:       String = ""
    var notes:            String?

    // MARK: Computed

    var storedURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(storedFileName)
    }

    var fileExists: Bool { FileManager.default.fileExists(atPath: storedURL.path) }

    var fileIcon: String {
        switch fileExtension.lowercased() {
        case "pdf":                    return "doc.fill"
        case "jpg", "jpeg", "png",
             "heic", "heif", "gif":    return "photo.fill"
        case "doc", "docx":            return "doc.text.fill"
        case "xls", "xlsx", "csv":     return "tablecells.fill"
        case "dwg", "dxf":             return "pencil.and.ruler.fill"
        case "mp4", "mov":             return "video.fill"
        case "zip", "rar":             return "archivebox.fill"
        default:                       return "doc.fill"
        }
    }

    var fileColor: Color {
        switch fileExtension.lowercased() {
        case "pdf":                    return .red
        case "jpg", "jpeg", "png",
             "heic", "heif", "gif":    return .teal
        case "doc", "docx":            return .blue
        case "xls", "xlsx", "csv":     return .green
        case "dwg", "dxf":             return .indigo
        default:                       return .gray
        }
    }

    var fileSizeString: String {
        let kb = Double(fileSize) / 1024
        let mb = kb / 1024
        if mb >= 1  { return String(format: "%.1f MB", mb) }
        if kb >= 1  { return String(format: "%.0f KB", kb) }
        return "\(fileSize) B"
    }
}

// MARK: - AppStore Extension

extension AppStore {

    var projectDocuments: [ProjectDocument] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = UserDefaults.standard.data(forKey: "bv_project_documents"),
              let docs  = try? decoder.decode([ProjectDocument].self, from: data)
        else { return [] }
        return docs
    }

    func documents(for projectID: UUID) -> [ProjectDocument] {
        projectDocuments
            .filter { $0.projectID == projectID }
            .sorted  { $0.uploadedAt > $1.uploadedAt }
    }

    func addDocument(_ doc: ProjectDocument) {
        var current = projectDocuments
        current.append(doc)
        saveDocMeta(current)
        objectWillChange.send()
    }

    func updateDocument(_ doc: ProjectDocument) {
        var current = projectDocuments
        if let i = current.firstIndex(where: { $0.id == doc.id }) { current[i] = doc }
        saveDocMeta(current)
        objectWillChange.send()
    }

    func deleteDocument(_ doc: ProjectDocument) {
        try? FileManager.default.removeItem(at: doc.storedURL)
        var current = projectDocuments
        current.removeAll { $0.id == doc.id }
        saveDocMeta(current)
        objectWillChange.send()
    }

    private func saveDocMeta(_ docs: [ProjectDocument]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(docs) {
            UserDefaults.standard.set(data, forKey: "bv_project_documents")
        }
    }
}

// MARK: - Project Documents Section (inline in ProjectDetailView)

struct ProjectDocumentsSection: View {
    let project: Project
    @EnvironmentObject var store: AppStore
    @State private var showPicker   = false
    @State private var showAllDocs  = false
    @State private var isImporting  = false

    private var docs: [ProjectDocument] { store.documents(for: project.id) }
    private var recent: [ProjectDocument] { Array(docs.prefix(4)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Section header
            HStack {
                SectionHeader(title: "Documents", count: docs.count)
                Spacer()
                if docs.count > 4 {
                    Button("View All") { showAllDocs = true }
                        .font(.subheadline)
                        .foregroundColor(.blue)
                        .padding(.trailing)
                }
            }

            if docs.isEmpty {
                EmptyCard(message: "No documents attached. Tap + to add contracts, drawings, permits, or photos.")
            } else {
                VStack(spacing: 0) {
                    ForEach(recent) { doc in
                        NavigationLink {
                            DocumentDetailView(document: doc)
                        } label: {
                            DocumentRow(doc: doc)
                        }
                        .buttonStyle(.plain)
                        if doc.id != recent.last?.id {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)
            }

            // Add Document button
            Button {
                showPicker = true
            } label: {
                HStack {
                    if isImporting {
                        ProgressView().tint(.white)
                        Text("Importing…")
                    } else {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Document")
                    }
                }
                .font(.subheadline).bold()
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.blue)
                .cornerRadius(12)
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .disabled(isImporting)
        }
        .sheet(isPresented: $showPicker) {
            DocumentPicker(allowedTypes: [.pdf, .image, .spreadsheet, .presentation,
                                          .text, .data, .item]) { urls in
                importFiles(urls)
            }
        }
        .sheet(isPresented: $showAllDocs) {
            ProjectDocumentListView(project: project)
        }
    }

    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        let projectID   = project.id
        let uploadedBy  = store.currentUser?.fullName ?? "Unknown"
        let docDir      = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        Task.detached(priority: .userInitiated) {
            var imported: [ProjectDocument] = []
            for url in urls {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                do {
                    let ext      = url.pathExtension.lowercased()
                    let fileName = "\(UUID().uuidString).\(ext)"
                    let destURL  = docDir.appendingPathComponent(fileName)
                    try FileManager.default.copyItem(at: url, to: destURL)
                    let size     = (try? FileManager.default
                        .attributesOfItem(atPath: destURL.path)[.size] as? Int) ?? 0
                    var doc = ProjectDocument(
                        projectID:        projectID,
                        name:             url.deletingPathExtension().lastPathComponent,
                        originalFileName: url.lastPathComponent,
                        fileExtension:    ext,
                        fileSize:         size,
                        storedFileName:   fileName
                    )
                    doc.uploadedBy  = uploadedBy
                    doc.uploadedAt  = Date()
                    doc.category    = guessCategory(ext: ext, name: url.lastPathComponent)
                    imported.append(doc)
                } catch {
                    // Skip files that can't be copied
                }
            }
            await MainActor.run {
                for doc in imported { store.addDocument(doc) }
                isImporting = false
            }
        }
    }

    private func guessCategory(ext: String, name: String) -> ProjectDocumentCategory {
        let lower = name.lowercased()
        if lower.contains("contract") || lower.contains("agreement") { return .contract }
        if lower.contains("drawing") || lower.contains("dwg") || ext == "dwg" { return .drawing }
        if lower.contains("permit")  { return .permit }
        if lower.contains("safety")  || lower.contains("msds") || lower.contains("sds") { return .safety }
        if lower.contains("quote")   || lower.contains("estimate") { return .quote }
        if lower.contains("report")  { return .report }
        if ["jpg","jpeg","png","heic","heif","gif"].contains(ext) { return .photo }
        return .other
    }
}

// MARK: - Document Row

struct DocumentRow: View {
    let doc: ProjectDocument

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(doc.fileColor.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: doc.fileIcon)
                    .foregroundColor(doc.fileColor)
                    .font(.system(size: 16))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(doc.name)
                    .font(.subheadline).bold()
                    .lineLimit(1)
                    .foregroundColor(.primary)
                HStack(spacing: 6) {
                    Text(doc.category.displayName)
                        .font(.caption2).bold()
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(doc.category.color.opacity(0.12))
                        .foregroundColor(doc.category.color)
                        .cornerRadius(4)
                    Text(doc.fileSizeString)
                        .font(.caption).foregroundColor(.secondary)
                    Text("·").font(.caption).foregroundColor(.secondary)
                    Text(doc.uploadedAt.shortDate)
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            Spacer()

            if !doc.fileExists {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                    .font(.caption)
            } else {
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Document Detail View

struct DocumentDetailView: View {
    let document: ProjectDocument
    var allowEdit: Bool = true
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var showPreview    = false
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var showEdit       = false
    @State private var showDeleteAlert = false
    @State private var localDoc: ProjectDocument

    init(document: ProjectDocument, allowEdit: Bool = true) {
        self.document = document
        self.allowEdit = allowEdit
        self._localDoc = State(initialValue: document)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // File hero card
                    VStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(localDoc.fileColor.opacity(0.10))
                                .frame(width: 80, height: 80)
                            Image(systemName: localDoc.fileIcon)
                                .font(.system(size: 34))
                                .foregroundColor(localDoc.fileColor)
                        }
                        Text(localDoc.name)
                            .font(.title3).bold()
                            .multilineTextAlignment(.center)
                        Text(localDoc.originalFileName)
                            .font(.caption).foregroundColor(.secondary)

                        HStack(spacing: 10) {
                            Label(localDoc.category.displayName, systemImage: localDoc.category.icon)
                                .font(.caption).bold()
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(localDoc.category.color.opacity(0.12))
                                .foregroundColor(localDoc.category.color)
                                .cornerRadius(8)
                            Text(localDoc.fileSizeString)
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(16)
                    .padding(.horizontal)

                    // Metadata
                    VStack(spacing: 0) {
                        InfoRow(label: "Uploaded by", value: localDoc.uploadedBy.isEmpty ? "—" : localDoc.uploadedBy)
                        Divider().padding(.leading)
                        InfoRow(label: "Uploaded",    value: localDoc.uploadedAt.shortDate)
                        Divider().padding(.leading)
                        InfoRow(label: "File type",   value: localDoc.fileExtension.uppercased())
                        Divider().padding(.leading)
                        InfoRow(label: "File size",   value: localDoc.fileSizeString)
                    }
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)

                    // Notes
                    if let notes = localDoc.notes, !notes.isEmpty {
                        SectionHeader(title: "Notes")
                        Text(notes)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                            .padding(.horizontal)
                    }

                    if !localDoc.fileExists {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            Text("File not found on this device.")
                                .font(.subheadline).foregroundColor(.orange)
                        }
                        .padding()
                        .background(Color.orange.opacity(0.08))
                        .cornerRadius(12)
                        .padding(.horizontal)
                    }

                    // Actions
                    VStack(spacing: 10) {
                        if localDoc.fileExists {
                            Button {
                                showPreview = true
                            } label: {
                                Label("Open / Preview", systemImage: "eye.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity).padding()
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(12)
                            }

                            Button {
                                shareItems = [localDoc.storedURL]
                                showShareSheet = true
                            } label: {
                                Label("Share / Export", systemImage: "square.and.arrow.up")
                                    .font(.subheadline).bold()
                                    .frame(maxWidth: .infinity).padding()
                                    .background(Color.blue.opacity(0.10))
                                    .foregroundColor(.blue)
                                    .cornerRadius(12)
                            }
                        }

                        if allowEdit {
                            Button(role: .destructive) {
                                showDeleteAlert = true
                            } label: {
                                Label("Delete Document", systemImage: "trash")
                                    .font(.subheadline).bold()
                                    .frame(maxWidth: .infinity).padding()
                                    .background(Color.red.opacity(0.10))
                                    .foregroundColor(.red)
                                    .cornerRadius(12)
                            }
                        }
                    }
                    .padding(.horizontal)

                    Spacer(minLength: 32)
                }
                .padding(.top)
            }
            .navigationTitle("Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if allowEdit {
                        Button("Edit") { showEdit = true }
                    }
                }
            }
            .fullScreenCover(isPresented: $showPreview) {
                QuickLookPreview(url: localDoc.storedURL)
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(items: shareItems)
            }
            .sheet(isPresented: $showEdit) {
                DocumentEditView(document: localDoc) { updated in
                    localDoc = updated
                    store.updateDocument(updated)
                }
            }
            .alert("Delete Document?", isPresented: $showDeleteAlert) {
                Button("Delete", role: .destructive) {
                    store.deleteDocument(localDoc)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes the file from this device. It cannot be undone.")
            }
        }
    }
}

// MARK: - Document Edit View

struct DocumentEditView: View {
    @State private var name:     String
    @State private var category: ProjectDocumentCategory
    @State private var notes:    String
    let onSave: (ProjectDocument) -> Void
    private let document: ProjectDocument
    @Environment(\.dismiss) var dismiss

    init(document: ProjectDocument, onSave: @escaping (ProjectDocument) -> Void) {
        self.document = document
        self.onSave   = onSave
        _name     = State(initialValue: document.name)
        _category = State(initialValue: document.category)
        _notes    = State(initialValue: document.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Document Name") {
                    TextField("Name", text: $name)
                }
                Section("Category") {
                    Picker("Category", selection: $category) {
                        ForEach(ProjectDocumentCategory.allCases) { cat in
                            Label(cat.displayName, systemImage: cat.icon).tag(cat)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 80)
                }
            }
            .navigationTitle("Edit Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        var updated = document
                        updated.name     = name.isEmpty ? document.originalFileName : name
                        updated.category = category
                        updated.notes    = notes.isEmpty ? nil : notes
                        onSave(updated)
                        dismiss()
                    }
                    .bold()
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Full Document List View

struct ProjectDocumentListView: View {
    let project: Project
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var searchText   = ""
    @State private var filterCat: ProjectDocumentCategory? = nil
    @State private var showPicker   = false
    @State private var isImporting  = false

    private var docs: [ProjectDocument] {
        store.documents(for: project.id)
            .filter { filterCat == nil || $0.category == filterCat }
            .filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText)
                      || $0.originalFileName.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if docs.isEmpty && searchText.isEmpty && filterCat == nil {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No documents yet")
                            .font(.headline)
                        Text("Tap + to add contracts, drawings, permits, or photos.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        Button("Add Document") { showPicker = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        // Category filter chips
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                FilterChip(label: "All",     isSelected: filterCat == nil) { filterCat = nil }
                                ForEach(ProjectDocumentCategory.allCases) { cat in
                                    let count = store.documents(for: project.id).filter { $0.category == cat }.count
                                    if count > 0 {
                                        FilterChip(label: "\(cat.displayName) (\(count))",
                                                   isSelected: filterCat == cat) { filterCat = cat }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowSeparator(.hidden)

                        if docs.isEmpty {
                            Text("No documents match your filter.")
                                .font(.subheadline).foregroundColor(.secondary)
                                .listRowSeparator(.hidden)
                        } else {
                            ForEach(docs) { doc in
                                NavigationLink {
                                    DocumentDetailView(document: doc)
                                } label: {
                                    DocumentRow(doc: doc)
                                        .padding(.vertical, 2)
                                }
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16))
                            }
                            .onDelete { offsets in
                                offsets.map { docs[$0] }.forEach { store.deleteDocument($0) }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .searchable(text: $searchText, prompt: "Search documents")
                }
            }
            .navigationTitle("Documents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isImporting {
                        ProgressView()
                    } else {
                        Button { showPicker = true } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showPicker) {
                DocumentPicker(allowedTypes: [.pdf, .image, .spreadsheet, .presentation, .text, .data, .item]) { urls in
                    importFiles(urls)
                }
            }
        }
    }

    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        let projectID  = project.id
        let uploadedBy = store.currentUser?.fullName ?? "Unknown"
        let docDir     = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        Task.detached(priority: .userInitiated) {
            var imported: [ProjectDocument] = []
            for url in urls {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                do {
                    let ext      = url.pathExtension.lowercased()
                    let fileName = "\(UUID().uuidString).\(ext)"
                    let destURL  = docDir.appendingPathComponent(fileName)
                    try FileManager.default.copyItem(at: url, to: destURL)
                    let size     = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int) ?? 0
                    var doc = ProjectDocument(
                        projectID:        projectID,
                        name:             url.deletingPathExtension().lastPathComponent,
                        originalFileName: url.lastPathComponent,
                        fileExtension:    ext,
                        fileSize:         size,
                        storedFileName:   fileName
                    )
                    doc.uploadedBy = uploadedBy
                    doc.uploadedAt = Date()
                    imported.append(doc)
                } catch {}
            }
            await MainActor.run {
                for doc in imported { store.addDocument(doc) }
                isImporting = false
            }
        }
    }
}

// MARK: - Document Picker (UIDocumentPickerViewController wrapper)

struct DocumentPicker: UIViewControllerRepresentable {
    let allowedTypes: [UTType]
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: allowedTypes)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) { onPick(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}

// MARK: - Quick Look Preview (QLPreviewController wrapper)

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let vc = QLPreviewControllerWrapper(url: url)
        return UINavigationController(rootViewController: vc)
    }

    func updateUIViewController(_ nav: UINavigationController, context: Context) {}
}

private final class QLPreviewControllerWrapper: QLPreviewController, QLPreviewControllerDataSource {
    private let url: URL

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
        self.dataSource = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController,
                           previewItemAt index: Int) -> QLPreviewItem {
        url as NSURL
    }
}

// MARK: - Reusable Info Row

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .bold()
        }
        .padding()
    }
}

// MARK: - Client Documents View (Client role tab)

struct ClientDocumentsView: View {
    @EnvironmentObject var store: AppStore
    @State private var searchText = ""
    @State private var selectedCategory: ProjectDocumentCategory? = nil
    @State private var selectedDocument: ProjectDocument? = nil

    private var allDocs: [ProjectDocument] {
        store.projects.flatMap { store.documents(for: $0.id) }
            .sorted { $0.uploadedAt > $1.uploadedAt }
    }

    private var filteredDocs: [ProjectDocument] {
        allDocs.filter { doc in
            let matchesSearch = searchText.isEmpty ||
                doc.name.localizedCaseInsensitiveContains(searchText) ||
                doc.originalFileName.localizedCaseInsensitiveContains(searchText)
            let matchesCat = selectedCategory == nil || doc.category == selectedCategory
            return matchesSearch && matchesCat
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if allDocs.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 52))
                            .foregroundColor(.secondary.opacity(0.4))
                        Text("No Documents Yet")
                            .font(.headline)
                        Text("Documents shared with you will appear here.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        // Category filter chips
                        if !allDocs.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    CategoryChip(
                                        title: "All",
                                        color: .blue,
                                        isSelected: selectedCategory == nil
                                    ) { selectedCategory = nil }
                                    ForEach(ProjectDocumentCategory.allCases, id: \.self) { cat in
                                        if allDocs.contains(where: { $0.category == cat }) {
                                            CategoryChip(
                                                title: cat.displayName,
                                                color: cat.color,
                                                isSelected: selectedCategory == cat
                                            ) {
                                                selectedCategory = selectedCategory == cat ? nil : cat
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 4)
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                            .listRowSeparator(.hidden)
                        }

                        if filteredDocs.isEmpty {
                            Text("No documents match your filter.")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        } else {
                            ForEach(filteredDocs) { doc in
                                Button {
                                    selectedDocument = doc
                                } label: {
                                    DocumentRow(doc: doc)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .searchable(text: $searchText, prompt: "Search documents…")
                }
            }
            .navigationTitle("Documents")
            .sheet(item: $selectedDocument) { doc in
                NavigationStack {
                    DocumentDetailView(document: doc, allowEdit: false)
                }
            }
        }
    }
}

private struct CategoryChip: View {
    let title: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption).bold()
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? color : color.opacity(0.1))
                .foregroundColor(isSelected ? .white : color)
                .cornerRadius(20)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sample-data tracking
extension ProjectDocument: SampleDataTrackable {}
