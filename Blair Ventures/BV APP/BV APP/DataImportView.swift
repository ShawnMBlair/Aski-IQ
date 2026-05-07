// DataImportView.swift
// Aski IQ – Enterprise Data Import UI

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Root View

struct DataImportView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var step: ImportStep = .selectType
    @State private var recordType: ImportRecordType = .clients

    // File
    @State private var fileData:    Data?
    @State private var fileName:    String = ""
    @State private var fileHeaders: [String] = []
    @State private var rawRows:     [[String]] = []
    @State private var fileError:   String?
    @State private var showFilePicker = false

    // Mapping
    @State private var mappings: [ColumnMapping] = []

    // Validation
    @State private var importRows: [ImportRow] = []
    @State private var isValidating = false

    // Processing
    @State private var isProcessing = false
    @State private var currentBatch: ImportBatch?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Step indicator
                StepIndicatorView(current: step)
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                Divider()

                // Step content
                Group {
                    switch step {
                    case .selectType:
                        SelectTypeStep(selected: $recordType)
                    case .uploadFile:
                        UploadFileStep(
                            fileName: $fileName,
                            fileError: $fileError,
                            showFilePicker: $showFilePicker,
                            fileLoaded: fileData != nil
                        )
                    case .mapColumns:
                        MapColumnsStep(
                            recordType: recordType,
                            headers: fileHeaders,
                            mappings: $mappings
                        )
                    case .preview:
                        PreviewStep(
                            rows: $importRows,
                            recordType: recordType,
                            isValidating: isValidating
                        )
                    case .processing:
                        ProcessingStep(batch: currentBatch)
                    case .summary:
                        SummaryStep(batch: currentBatch) {
                            dismiss()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                // Navigation buttons
                ImportNavButtons(
                    step: $step,
                    canAdvance: canAdvance,
                    onNext: handleNext,
                    onBack: { step = ImportStep(rawValue: step.rawValue - 1) ?? .selectType },
                    onCancel: { dismiss() }
                )
                .padding()
            }
            .navigationTitle(step.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [UTType.commaSeparatedText, UTType.plainText],
                allowsMultipleSelection: false
            ) { result in
                handleFilePicked(result)
            }
        }
    }

    // MARK: - Can Advance

    private var canAdvance: Bool {
        switch step {
        case .selectType:  return true
        case .uploadFile:  return fileData != nil && fileError == nil
        case .mapColumns:  return hasRequiredMappings
        case .preview:     return importRows.contains { !$0.isSkipped && !$0.hasErrors }
        case .processing:  return false
        case .summary:     return false
        }
    }

    private var hasRequiredMappings: Bool {
        let mapped = Set(mappings.compactMap(\.systemField))
        return recordType.requiredFields.allSatisfy { mapped.contains($0) }
    }

    // MARK: - Handle Next

    private func handleNext() {
        switch step {
        case .selectType:
            step = .uploadFile
        case .uploadFile:
            buildMappings()
            step = .mapColumns
        case .mapColumns:
            buildImportRows()
            runValidation()
            step = .preview
        case .preview:
            runImport()
        case .processing, .summary:
            break
        }
    }

    // MARK: - File Handling

    private func handleFilePicked(_ result: Result<[URL], Error>) {
        fileError = nil
        fileData  = nil
        fileName  = ""
        fileHeaders = []
        rawRows     = []

        switch result {
        case .failure(let err):
            fileError = err.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                fileError = "Permission denied. Please try again."; return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            let ext = url.pathExtension.lowercased()
            guard ext == "csv" || ext == "txt" else {
                fileError = ImportFileError.invalidFileType.errorDescription; return
            }

            do {
                let data = try Data(contentsOf: url)
                let (headers, rows) = try CSVParser.parse(data)
                fileData    = data
                fileName    = url.lastPathComponent
                fileHeaders = headers
                rawRows     = rows
            } catch {
                fileError = error.localizedDescription
            }
        }
    }

    // MARK: - Mapping Builder

    private func buildMappings() {
        let systemFields = recordType.availableFields.map(\.key)
        mappings = fileHeaders.map { header in
            let suggested = autoSuggest(header: header, systemFields: systemFields)
            return ColumnMapping(spreadsheetColumn: header, systemField: suggested)
        }
    }

    /// Auto-suggest a system field key from a spreadsheet column header
    private func autoSuggest(header: String, systemFields: [String]) -> String? {
        let h = header.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")

        // Direct match
        if systemFields.contains(h) { return h }

        // Common aliases
        let aliases: [String: String] = [
            "company":          "client_name",
            "company_name":     "client_name",
            "client":           "client_name",
            "name":             "client_name",
            "organisation":     "client_name",
            "organization":     "client_name",
            "email":            "contact_email",
            "e_mail":           "contact_email",
            "phone":            "contact_phone",
            "telephone":        "contact_phone",
            "mobile":           "contact_phone",
            "contact":          "contact_name",
            "primary_contact":  "contact_name",
            "address":          "billing_address",
            "street":           "billing_address",
            "city":             "billing_city",
            "province":         "billing_province",
            "state":            "billing_province",
            "postal":           "billing_postal",
            "postal_code":      "billing_postal",
            "postcode":         "billing_postal",
            "post_code":        "billing_postal",
            "zip":              "billing_postal",
            "zip_code":         "billing_postal",
            "zipcode":          "billing_postal",
            "code":             "client_code",
            "ref":              "external_id",
            "reference":        "external_id",
            "action":           "action_type",
            "id":               "app_record_id",
        ]
        return aliases[h]
    }

    // MARK: - Import Rows Builder

    private func buildImportRows() {
        importRows = rawRows.enumerated().map { idx, values in
            let raw = Dictionary(uniqueKeysWithValues: zip(fileHeaders, values))
            return ImportRow(rowIndex: idx + 2, rawData: raw, mappedData: [:])
        }
    }

    // MARK: - Validation

    private func runValidation() {
        isValidating = true
        let engine = ImportValidationEngine(store: store)
        engine.validate(rows: &importRows, recordType: recordType, mappings: mappings)
        isValidating = false
    }

    // MARK: - Import Processing

    private func runImport() {
        guard let companyID = store.currentCompanyID,
              let userID    = store.currentUser?.id else { return }

        step = .processing
        isProcessing = true

        var batch = ImportBatch(
            companyID:  companyID,
            uploadedBy: userID,
            fileName:   fileName,
            recordType: recordType.rawValue,
            status:     .importing,
            totalRows:  importRows.count
        )
        currentBatch = batch

        Task {
            let processor = ImportProcessor(store: store)
            var result = (created: 0, updated: 0, skipped: 0, errors: 0)

            switch recordType {
            case .clients:
                result = processor.processClients(rows: importRows, batchID: batch.id)
            default:
                // Future record types wire in here
                result.skipped = importRows.count
            }

            await MainActor.run {
                batch.created    = result.created
                batch.updated    = result.updated
                batch.skipped    = result.skipped
                batch.errorCount = result.errors
                batch.status     = result.errors > 0 && result.created == 0 && result.updated == 0
                                   ? .failed : .completed
                batch.completedAt = Date()

                currentBatch = batch
                store.recordImportBatch(batch)
                isProcessing = false
                step = .summary
            }
        }
    }
}

// MARK: - Step 1: Select Type

private struct SelectTypeStep: View {
    @Binding var selected: ImportRecordType

    let available: [ImportRecordType] = [.clients, .contacts, .projects,
                                          .estimates, .employees, .equipment]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("What data are you importing?")
                    .font(.headline)
                    .padding(.horizontal)
                    .padding(.top, 16)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(available) { type in
                        RecordTypeCard(type: type, isSelected: selected == type) {
                            selected = type
                        }
                    }
                }
                .padding(.horizontal)

                if selected != .clients {
                    Label("Full support for this type is coming soon. Clients are fully supported now.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }
            }
            .padding(.bottom, 24)
        }
    }
}

private struct RecordTypeCard: View {
    let type: ImportRecordType
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 10) {
                Image(systemName: type.icon)
                    .font(.title2)
                    .foregroundColor(isSelected ? .white : type.color)
                Text(type.rawValue)
                    .font(.subheadline).bold()
                    .foregroundColor(isSelected ? .white : .primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(isSelected ? type.color : Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? type.color : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step 2: Upload File

private struct UploadFileStep: View {
    @Binding var fileName:      String
    @Binding var fileError:     String?
    @Binding var showFilePicker: Bool
    let fileLoaded: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Drop zone / file picker
                Button { showFilePicker = true } label: {
                    VStack(spacing: 14) {
                        Image(systemName: fileLoaded ? "checkmark.circle.fill" : "arrow.up.doc.fill")
                            .font(.system(size: 44))
                            .foregroundColor(fileLoaded ? .green : .accentColor)

                        if fileLoaded {
                            Text(fileName)
                                .font(.headline)
                            Text("Tap to replace")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Select CSV File")
                                .font(.headline)
                            Text("Tap to browse your files")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(40)
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(fileLoaded ? Color.green : Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal)

                if let err = fileError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }

                // Template guide
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Client Import Template (v1.0)", systemImage: "doc.text")
                            .font(.subheadline).bold()
                        Text("Your CSV should have these column headers:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ForEach(clientTemplateColumns, id: \.self) { col in
                            HStack(spacing: 6) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 5))
                                    .foregroundColor(.secondary)
                                Text(col)
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 20)
        }
    }

    private let clientTemplateColumns = [
        "client_name *",
        "client_code",
        "contact_name",
        "contact_email",
        "contact_phone",
        "billing_address",
        "billing_city",
        "billing_province",
        "billing_postal",
        "notes",
        "action_type",
    ]
}

// MARK: - Step 3: Map Columns

private struct MapColumnsStep: View {
    let recordType: ImportRecordType
    let headers: [String]
    @Binding var mappings: [ColumnMapping]

    private var systemFieldOptions: [ImportSystemField] {
        recordType.availableFields
    }

    var body: some View {
        List {
            Section {
                Label("Map each spreadsheet column to an Aski IQ field. Unmapped columns are ignored.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Column Mappings") {
                ForEach($mappings) { $mapping in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mapping.spreadsheetColumn)
                                .font(.subheadline).bold()
                            Text("Spreadsheet column")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Picker("", selection: $mapping.systemField) {
                            Text("Ignore").tag(String?.none)
                            ForEach(systemFieldOptions) { field in
                                Text(field.label)
                                    .tag(Optional(field.key))
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - Step 4: Preview

private struct PreviewStep: View {
    @Binding var rows: [ImportRow]
    let recordType: ImportRecordType
    let isValidating: Bool

    private var cleanRows:   [ImportRow] { rows.filter { $0.effectiveState == .clean   } }
    private var warningRows: [ImportRow] { rows.filter { $0.effectiveState == .warning } }
    private var errorRows:   [ImportRow] { rows.filter { $0.effectiveState == .error   } }
    private var skippedRows: [ImportRow] { rows.filter { $0.effectiveState == .skipped } }

    var body: some View {
        if isValidating {
            VStack(spacing: 12) {
                ProgressView()
                Text("Validating…").foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                // Summary bar
                Section {
                    HStack(spacing: 0) {
                        SummaryPill(count: cleanRows.count,   label: "Ready",   color: .green)
                        SummaryPill(count: warningRows.count, label: "Warning",  color: .orange)
                        SummaryPill(count: errorRows.count,   label: "Errors",   color: .red)
                        SummaryPill(count: skippedRows.count, label: "Skipped",  color: .secondary)
                    }
                }

                // Error rows
                if !errorRows.isEmpty {
                    Section("Blocked — Fix Required (\(errorRows.count))") {
                        ForEach(errorRows) { row in
                            PreviewRowView(row: row, onSkip: { toggleSkip(row) })
                        }
                    }
                }

                // Warning rows
                if !warningRows.isEmpty {
                    Section("Warnings — Review (\(warningRows.count))") {
                        ForEach(warningRows) { row in
                            PreviewRowView(row: row, onSkip: { toggleSkip(row) })
                        }
                    }
                }

                // Clean rows
                if !cleanRows.isEmpty {
                    Section("Ready to Import (\(cleanRows.count))") {
                        ForEach(cleanRows) { row in
                            PreviewRowView(row: row, onSkip: { toggleSkip(row) })
                        }
                    }
                }

                // Skipped rows
                if !skippedRows.isEmpty {
                    Section("Skipped (\(skippedRows.count))") {
                        ForEach(skippedRows) { row in
                            PreviewRowView(row: row, onSkip: { toggleSkip(row) })
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func toggleSkip(_ row: ImportRow) {
        guard let idx = rows.firstIndex(where: { $0.id == row.id }) else { return }
        rows[idx].isSkipped.toggle()
        rows[idx].state = rows[idx].effectiveState
    }
}

private struct SummaryPill: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.title3).bold()
                .foregroundColor(color)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PreviewRowView: View {
    let row: ImportRow
    let onSkip: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: row.effectiveState.icon)
                    .foregroundColor(row.effectiveState.color)

                Text(row.mappedData["client_name"] ?? row.mappedData.values.first ?? "Row \(row.rowIndex)")
                    .font(.subheadline).bold()

                Spacer()

                Button(row.isSkipped ? "Unskip" : "Skip") { onSkip() }
                    .font(.caption)
                    .buttonStyle(.bordered)

                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
            }

            if expanded {
                ForEach(row.issues) { issue in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: issue.isBlocking ? "xmark.circle" : "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundColor(issue.isBlocking ? .red : .orange)
                        Text(issue.message)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                ForEach(Array(row.mappedData.sorted(by: { $0.key < $1.key })), id: \.key) { key, val in
                    if !val.isEmpty {
                        HStack {
                            Text(key)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .frame(width: 110, alignment: .leading)
                            Text(val)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Step 5: Processing

private struct ProcessingStep: View {
    let batch: ImportBatch?

    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.4)
            Text("Importing \(batch?.recordType ?? "records")…")
                .font(.headline)
            Text("Do not close this screen.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Step 6: Summary

private struct SummaryStep: View {
    let batch: ImportBatch?
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Status badge
                let status = batch?.status ?? .completed
                VStack(spacing: 8) {
                    Image(systemName: status.icon)
                        .font(.system(size: 52))
                        .foregroundColor(status.color)
                    Text(status.rawValue)
                        .font(.title2).bold()
                        .foregroundColor(status.color)
                }
                .padding(.top, 24)

                // Stats
                if let b = batch {
                    GroupBox("Import Summary") {
                        VStack(spacing: 10) {
                            SummaryStatRow(label: "Total Rows",    value: "\(b.totalRows)",  icon: "list.number",             color: .primary)
                            SummaryStatRow(label: "Created",       value: "\(b.created)",    icon: "plus.circle.fill",         color: .green)
                            SummaryStatRow(label: "Updated",       value: "\(b.updated)",    icon: "arrow.triangle.2.circlepath", color: .blue)
                            SummaryStatRow(label: "Skipped",       value: "\(b.skipped)",    icon: "minus.circle.fill",        color: .secondary)
                            SummaryStatRow(label: "Errors",        value: "\(b.errorCount)", icon: "xmark.circle.fill",        color: b.errorCount > 0 ? .red : .secondary)
                        }
                    }
                    .padding(.horizontal)

                    // Batch ID (for support/rollback)
                    GroupBox("Batch Info") {
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("Batch ID") {
                                Text(b.id.uuidString.prefix(8).uppercased())
                                    .font(.system(.caption, design: .monospaced))
                            }
                            LabeledContent("File") {
                                Text(b.fileName).font(.caption).lineLimit(1)
                            }
                            if let completed = b.completedAt {
                                LabeledContent("Completed") {
                                    Text(completed.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }

                Button("Done") { onDone() }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
            }
            .padding(.bottom, 32)
        }
    }
}

private struct SummaryStatRow: View {
    let label: String
    let value: String
    let icon:  String
    let color: Color

    var body: some View {
        HStack {
            Label(label, systemImage: icon)
                .foregroundColor(color)
            Spacer()
            Text(value)
                .font(.headline)
                .foregroundColor(color)
        }
    }
}

// MARK: - Step Indicator

private struct StepIndicatorView: View {
    let current: ImportStep

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(ImportStep.allCases.prefix(6).enumerated()), id: \.offset) { idx, s in
                Circle()
                    .fill(s.rawValue <= current.rawValue ? Color.accentColor : Color(.systemGray4))
                    .frame(width: 10, height: 10)
                if idx < ImportStep.allCases.count - 1 {
                    Rectangle()
                        .fill(s.rawValue < current.rawValue ? Color.accentColor : Color(.systemGray4))
                        .frame(height: 2)
                }
            }
        }
    }
}

// MARK: - Navigation Buttons

private struct ImportNavButtons: View {
    @Binding var step: ImportStep
    let canAdvance: Bool
    let onNext:   () -> Void
    let onBack:   () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack {
            if step.rawValue > 0 && step != .processing && step != .summary {
                Button("Back", action: onBack)
                    .buttonStyle(.bordered)
            }

            Spacer()

            if step != .processing && step != .summary {
                Button(nextLabel, action: onNext)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdvance)
            }
        }
    }

    private var nextLabel: String {
        switch step {
        case .preview:   return "Import Now"
        default:         return "Next"
        }
    }
}

// MARK: - AppStore extension

extension AppStore {

    func recordImportBatch(_ batch: ImportBatch) {
        importBatches.append(batch)
        Task { await SyncEngine.shared.pushImportBatch(batch) }
    }

    /// Rollback: delete all records created in a given batch.
    /// (Clients only in v1.0 — expand per record type)
    func rollback(batchID: UUID) {
        // For a real rollback you'd track which record IDs were created in this batch.
        // This placeholder marks the batch as rolled back in the audit trail.
        if let idx = importBatches.firstIndex(where: { $0.id == batchID }) {
            importBatches[idx].status = .rolledBack
            Task { await SyncEngine.shared.pushImportBatch(importBatches[idx]) }
        }
    }
}
