// MultiTabImportView.swift
// Aski IQ – Multi-Tab Workbook Import UI

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Root View

struct MultiTabImportView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var phase: ImportPhase = .upload
    @State private var fileName = ""
    @State private var fileData: Data?
    @State private var fileError: String?
    @State private var showFilePicker = false

    // Parsed from Edge Function
    @State private var parsedTabs: [ImportRecordType: [ImportRow]] = [:]
    @State private var isParsing = false
    @State private var parseError: String?

    // Validation
    @State private var isValidating = false
    @State private var validatedTabs: [ImportRecordType: [ImportRow]] = [:]

    // Preview selection
    @State private var selectedTab: ImportRecordType?

    // Processing
    @State private var isProcessing = false
    @State private var batchResult: MultiTabBatchResult?

    enum ImportPhase { case upload, parsing, preview, processing, summary }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PhaseIndicator(phase: phase)
                    .padding(.horizontal).padding(.top, 12).padding(.bottom, 8)
                Divider()

                switch phase {
                case .upload:     uploadPhase
                case .parsing:    parsingPhase
                case .preview:    previewPhase
                case .processing: processingPhase
                case .summary:    summaryPhase
                }
            }
            .navigationTitle(phaseTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if phase == .upload || phase == .preview {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if phase == .upload {
                        Button("Help") { }
                            .font(.caption)
                    }
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [
                    UTType(filenameExtension: "xlsx") ?? .data,
                    UTType(filenameExtension: "xls")  ?? .data,
                ],
                allowsMultipleSelection: false
            ) { result in
                handleFilePicked(result)
            }
        }
    }

    // MARK: - Phase Title

    private var phaseTitle: String {
        switch phase {
        case .upload:     return "Import Workbook"
        case .parsing:    return "Reading File…"
        case .preview:    return "Preview & Validate"
        case .processing: return "Importing…"
        case .summary:    return "Import Complete"
        }
    }

    // MARK: - Upload Phase

    private var uploadPhase: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Drop zone
                Button { showFilePicker = true } label: {
                    VStack(spacing: 16) {
                        Image(systemName: fileData != nil ? "checkmark.circle.fill" : "arrow.up.doc.fill")
                            .font(.system(size: 52))
                            .foregroundColor(fileData != nil ? .green : .accentColor)
                        if fileData != nil {
                            Text(fileName).font(.headline)
                            Text("Tap to replace").font(.caption).foregroundColor(.secondary)
                        } else {
                            Text("Select Workbook").font(.headline)
                            Text("Aski IQ Master Import Template .xlsx")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(44)
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .stroke(fileData != nil ? Color.green : Color.accentColor,
                                style: StrokeStyle(lineWidth: 2, dash: [6])))
                }
                .buttonStyle(.plain)
                .padding(.horizontal)

                if let err = fileError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundColor(.red).padding(.horizontal)
                }

                if let err = parseError {
                    Label(err, systemImage: "xmark.octagon.fill")
                        .font(.caption).foregroundColor(.red).padding(.horizontal)
                }

                // Company guard info
                if let companyID = store.currentCompanyID {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Importing into your company account", systemImage: "building.2.fill")
                                .font(.subheadline).bold()
                            Text("Company ID: \(companyID.uuidString.prefix(8).uppercased())…")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text("Every row in your workbook must have a matching company_id or leave it blank. Mismatched rows will be blocked.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal)
                }

                // Tabs preview
                GroupBox("Tabs Processed (in order)") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(ImportTabRegistry.all.sorted { $0.processingOrder < $1.processingOrder }.enumerated()), id: \.offset) { idx, tab in
                            HStack(spacing: 8) {
                                Text("\(tab.processingOrder).")
                                    .font(.caption2).foregroundColor(.secondary)
                                    .frame(width: 20, alignment: .trailing)
                                Image(systemName: tab.id.icon)
                                    .font(.caption).foregroundColor(tab.id.color)
                                Text(tab.sheetName)
                                    .font(.caption)
                            }
                        }
                    }
                }
                .padding(.horizontal)

                // Import button
                Button {
                    startParsing()
                } label: {
                    Label("Read & Validate Workbook", systemImage: "arrow.up.doc.badge.ellipsis")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(fileData != nil ? Color.accentColor : Color(.systemGray4))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .disabled(fileData == nil)
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .padding(.top, 20)
        }
    }

    // MARK: - Parsing Phase

    private var parsingPhase: some View {
        VStack(spacing: 20) {
            ProgressView().scaleEffect(1.4)
            Text("Reading workbook tabs…").font(.headline)
            Text("Validating all rows against your account data.")
                .font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Preview Phase

    private var previewPhase: some View {
        VStack(spacing: 0) {
            // Tab selector + global stats bar
            globalStatsBar
            Divider()

            // Tab list + row detail
            if validatedTabs.isEmpty {
                ContentUnavailableView(
                    "No Data Found",
                    systemImage: "doc.questionmark",
                    description: Text("The workbook had no data rows. Fill in the template tabs and re-upload.")
                )
            } else {
                HStack(spacing: 0) {
                    tabSidebar
                    Divider()
                    tabDetailPanel
                }
            }

            Divider()
            // Action bar
            HStack {
                Button("Back") { phase = .upload }
                    .buttonStyle(.bordered)
                Spacer()
                Button {
                    runImport()
                } label: {
                    Label("Import Valid Rows", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasImportableRows)
            }
            .padding()
        }
    }

    private var globalStatsBar: some View {
        let allRows = validatedTabs.values.flatMap { $0 }
        let clean   = allRows.filter { $0.effectiveState == .clean   }.count
        let warn    = allRows.filter { $0.effectiveState == .warning }.count
        let errors  = allRows.filter { $0.effectiveState == .error   }.count
        let skipped = allRows.filter { $0.isSkipped }.count

        return HStack(spacing: 0) {
            GlobalStatChip(count: clean,   label: "Ready",   color: .green)
            GlobalStatChip(count: warn,    label: "Warning", color: .orange)
            GlobalStatChip(count: errors,  label: "Blocked", color: .red)
            GlobalStatChip(count: skipped, label: "Skipped", color: .secondary)
        }
        .padding(.vertical, 8)
    }

    private var tabSidebar: some View {
        let tabs = validatedTabs.keys.sorted { $0.processingOrder < $1.processingOrder }
        return List(tabs, id: \.self, selection: $selectedTab) { type in
            TabSidebarRow(
                type: type,
                rows: validatedTabs[type] ?? [],
                isSelected: selectedTab == type
            )
        }
        .listStyle(.sidebar)
        .frame(width: 160)
        .onAppear {
            if selectedTab == nil { selectedTab = tabs.first }
        }
    }

    private var tabDetailPanel: some View {
        Group {
            if let type = selectedTab, let rows = validatedTabs[type] {
                TabRowsDetail(
                    recordType: type,
                    rows: Binding(
                        get: { validatedTabs[type] ?? [] },
                        set: { validatedTabs[type] = $0 }
                    )
                )
            } else {
                Text("Select a tab").foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Processing Phase

    private var processingPhase: some View {
        VStack(spacing: 20) {
            ProgressView().scaleEffect(1.4)
            Text("Importing data…").font(.headline)
            Text("Processing tabs in the correct order.\nDo not close this screen.")
                .font(.caption).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Summary Phase

    private var summaryPhase: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56)).foregroundColor(.green)
                    .padding(.top, 24)

                Text("Import Complete").font(.title2).bold()

                if let result = batchResult {
                    GroupBox("Overall Summary") {
                        VStack(spacing: 10) {
                            SumRow(label: "Total Rows",  value: result.totalRows,    icon: "list.number",                 color: .primary)
                            SumRow(label: "Created",     value: result.totalCreated,  icon: "plus.circle.fill",             color: .green)
                            SumRow(label: "Updated",     value: result.totalUpdated,  icon: "arrow.triangle.2.circlepath",  color: .blue)
                            SumRow(label: "Skipped",     value: result.totalSkipped,  icon: "minus.circle.fill",            color: .secondary)
                            SumRow(label: "Errors",      value: result.totalErrors,   icon: "xmark.circle.fill",            color: result.totalErrors > 0 ? .red : .secondary)
                        }
                    }.padding(.horizontal)

                    GroupBox("By Tab") {
                        VStack(spacing: 6) {
                            ForEach(Array(result.tabResults.values.sorted { $0.recordType.processingOrder < $1.recordType.processingOrder }), id: \.recordType) { tab in
                                HStack {
                                    Image(systemName: tab.recordType.icon)
                                        .foregroundColor(tab.recordType.color)
                                    Text(tab.recordType.rawValue).font(.subheadline)
                                    Spacer()
                                    Text("+\(tab.created)").foregroundColor(.green).font(.caption).bold()
                                    Text("~\(tab.updated)").foregroundColor(.blue).font(.caption)
                                    if tab.errors > 0 {
                                        Text("✕\(tab.errors)").foregroundColor(.red).font(.caption)
                                    }
                                }
                            }
                        }
                    }.padding(.horizontal)

                    GroupBox("Batch Info") {
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("Batch ID") {
                                Text(result.batchID.uuidString.prefix(8).uppercased())
                                    .font(.system(.caption, design: .monospaced))
                            }
                            LabeledContent("File") { Text(fileName).font(.caption).lineLimit(1) }
                            LabeledContent("Completed") {
                                Text(Date().formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                            }
                        }
                    }.padding(.horizontal)
                }

                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8).padding(.bottom, 32)
            }
        }
    }

    // MARK: - File Handling

    private func handleFilePicked(_ result: Result<[URL], Error>) {
        fileError = nil; fileData = nil; fileName = ""
        switch result {
        case .failure(let e): fileError = e.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                fileError = "Permission denied."; return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            let ext = url.pathExtension.lowercased()
            guard ext == "xlsx" || ext == "xls" else {
                fileError = "Please select an .xlsx file."; return
            }
            do {
                fileData = try Data(contentsOf: url)
                fileName = url.lastPathComponent
            } catch { fileError = error.localizedDescription }
        }
    }

    // MARK: - Start Parsing (calls Supabase Edge Function)

    private func startParsing() {
        guard let data = fileData,
              let companyID = store.currentCompanyID else { return }
        phase = .parsing
        parseError = nil

        Task {
            do {
                let parsed = try await callParseFunction(data: data, companyID: companyID)
                var tabs: [ImportRecordType: [ImportRow]] = [:]

                for (typeRaw, tabData) in parsed {
                    guard let type = ImportRecordType(rawValue: typeRaw) else { continue }
                    let rows: [ImportRow] = tabData.map { rowData in
                        // The Excel template marks required columns with a " *" suffix
                        // (e.g. "client_name *"). Strip that suffix so keys match system field names.
                        let normalized = Self.normalizeImportKeys(rowData.data)
                        return ImportRow(
                            rowIndex: rowData.rowIndex,
                            rawData: normalized,
                            mappedData: normalized
                        )
                    }
                    tabs[type] = rows
                }

                // Validate all tabs
                let engine = MultiTabValidationEngine(store: store)
                engine.validateAll(tabs: &tabs, companyID: companyID)

                await MainActor.run {
                    validatedTabs = tabs
                    phase = .preview
                }
            } catch {
                await MainActor.run {
                    parseError = error.localizedDescription
                    phase = .upload
                }
            }
        }
    }

    // MARK: - Edge Function Call

    private func callParseFunction(data: Data, companyID: UUID) async throws -> [String: [ParsedRowDTO]] {
        let urlStr = "https://uiwjvkutaezyismkjwxj.supabase.co/functions/v1/parse-import-xlsx"
        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }

        let session = try await store.supabaseSession()

        var req = URLRequest(url: url)
        req.httpMethod = "POST"

        let boundary = UUID().uuidString
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

        var body = Data()
        // company_id field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"company_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(companyID.uuidString)\r\n".data(using: .utf8)!)
        // file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (respData, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: respData, encoding: .utf8) ?? "Unknown error"
            throw ImportParseError.serverError(msg)
        }

        let decoded = try JSONDecoder().decode(EdgeFunctionResponse.self, from: respData)
        return decoded.tabs.mapValues { $0.rows }
    }

    // MARK: - Key Normalisation

    /// Strips the " *" required-field marker that the Excel template appends to required
    /// column headers (e.g. "client_name *" → "client_name"). Also collapses any
    /// remaining leading/trailing whitespace so keys match system field names exactly.
    static func normalizeImportKeys(_ raw: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        result.reserveCapacity(raw.count)
        for (key, value) in raw {
            // Strip trailing " *" (with any surrounding spaces), then trim
            var normalized = key
            if normalized.hasSuffix("*") {
                normalized = String(normalized.dropLast()).trimmingCharacters(in: .whitespaces)
            }
            normalized = normalized.trimmingCharacters(in: .whitespaces)
            // If two columns collapse to the same key, prefer the non-empty value
            if let existing = result[normalized], !existing.isEmpty {
                continue
            }
            result[normalized] = value
        }
        return result
    }

    // MARK: - Computed

    private var hasImportableRows: Bool {
        validatedTabs.values.flatMap { $0 }.contains { !$0.isSkipped && !$0.hasErrors }
    }

    // MARK: - Run Import

    private func runImport() {
        guard let companyID = store.currentCompanyID,
              let userID    = store.currentUser?.id else { return }
        phase = .processing

        Task {
            var result = MultiTabBatchResult()
            let processor = ImportProcessor(store: store)

            // Process in relational order
            let orderedTypes = validatedTabs.keys.sorted { $0.processingOrder < $1.processingOrder }

            for type in orderedTypes {
                guard let rows = validatedTabs[type] else { continue }
                let total = rows.count

                var tabRes = TabResult(recordType: type, total: total,
                                       created: 0, updated: 0, skipped: 0, errors: 0, rows: rows)

                let r = processor.process(type: type, rows: rows, batchID: result.batchID)
                tabRes.created = r.created; tabRes.updated = r.updated
                tabRes.skipped = r.skipped; tabRes.errors  = r.errors

                result.tabResults[type] = tabRes
            }

            // Record batch — use result.batchID so summary and history both show the same ID
            let batch = ImportBatch(
                id:          result.batchID,
                companyID:   companyID,
                uploadedBy:  userID,
                fileName:    fileName,
                recordType:  "Multi-Tab",
                status:      result.totalErrors > 0 && result.totalCreated == 0 ? .failed : .completed,
                totalRows:   result.totalRows,
                created:     result.totalCreated,
                updated:     result.totalUpdated,
                skipped:     result.totalSkipped,
                errorCount:  result.totalErrors,
                completedAt: Date()
            )

            await MainActor.run {
                store.recordImportBatch(batch)
                batchResult = result
                phase = .summary
            }
        }
    }
}

// MARK: - Sidebar Row

private struct TabSidebarRow: View {
    let type: ImportRecordType
    let rows: [ImportRow]
    let isSelected: Bool

    private var errorCount:   Int { rows.filter { $0.effectiveState == .error   }.count }
    private var warningCount: Int { rows.filter { $0.effectiveState == .warning }.count }
    private var cleanCount:   Int { rows.filter { $0.effectiveState == .clean   }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(type.rawValue, systemImage: type.icon)
                .font(.caption).bold()
                .foregroundColor(isSelected ? type.color : .primary)
            HStack(spacing: 6) {
                if cleanCount   > 0 { Badge(count: cleanCount,   color: .green)   }
                if warningCount > 0 { Badge(count: warningCount, color: .orange)  }
                if errorCount   > 0 { Badge(count: errorCount,   color: .red)     }
                if rows.isEmpty     { Text("–").font(.caption2).foregroundColor(.secondary) }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct Badge: View {
    let count: Int; let color: Color
    var body: some View {
        Text("\(count)")
            .font(.caption2).bold()
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(4)
    }
}

// MARK: - Tab Row Detail

private struct TabRowsDetail: View {
    let recordType: ImportRecordType
    @Binding var rows: [ImportRow]

    var body: some View {
        List {
            if rows.isEmpty {
                Text("No rows on this tab.").foregroundColor(.secondary).font(.subheadline)
            } else {
                ForEach($rows) { $row in
                    ImportRowCell(row: $row)
                }
            }
        }
        .listStyle(.plain)
    }
}

private struct ImportRowCell: View {
    @Binding var row: ImportRow
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: row.effectiveState.icon)
                    .foregroundColor(row.effectiveState.color)
                Text(primaryLabel).font(.subheadline).bold()
                Spacer()
                Button(row.isSkipped ? "Unskip" : "Skip") {
                    row.isSkipped.toggle()
                    row.state = row.effectiveState
                }
                .font(.caption).buttonStyle(.bordered)

                Button { withAnimation { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
            }

            if expanded {
                ForEach(row.issues) { issue in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: issue.isBlocking ? "xmark.circle" : "exclamationmark.triangle")
                            .font(.caption).foregroundColor(issue.isBlocking ? .red : .orange)
                        Text(issue.message).font(.caption).foregroundColor(.secondary)
                    }
                }
                ForEach(Array(row.mappedData.sorted { $0.key < $1.key }), id: \.key) { k, v in
                    if !v.isEmpty {
                        HStack {
                            Text(k).font(.caption2).foregroundColor(.secondary).frame(width: 120, alignment: .leading)
                            Text(v).font(.caption).lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var primaryLabel: String {
        let d = row.mappedData
        if let v = d["client_name"],       !v.isEmpty { return v }
        if let v = d["project_name"],      !v.isEmpty { return v }
        if let v = d["opportunity_name"],  !v.isEmpty { return v }
        if let fn = d["first_name"], let ln = d["last_name"] { return "\(fn) \(ln)" }
        if let v = d["vendor_name"],       !v.isEmpty { return v }
        if let v = d["equipment_name"],    !v.isEmpty { return v }
        if let v = d["product_name"],      !v.isEmpty { return v }
        if let v = d["document_name"],     !v.isEmpty { return v }
        if let v = d["form_type"],         !v.isEmpty { return v }
        if let v = d["form_template_name"],!v.isEmpty { return v }
        if let v = d["company_name"],      !v.isEmpty { return v }
        return "Row \(row.rowIndex)"
    }
}

// MARK: - Phase Indicator

private struct PhaseIndicator: View {
    let phase: MultiTabImportView.ImportPhase
    let phases: [(MultiTabImportView.ImportPhase, String)] = [
        (.upload, "Upload"), (.parsing, "Parse"), (.preview, "Preview"),
        (.processing, "Import"), (.summary, "Done"),
    ]

    private func order(_ p: MultiTabImportView.ImportPhase) -> Int {
        switch p {
        case .upload: return 0; case .parsing: return 1; case .preview: return 2
        case .processing: return 3; case .summary: return 4
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(phases, id: \.1) { (p, label) in
                VStack(spacing: 4) {
                    Circle()
                        .fill(order(p) <= order(phase) ? Color.accentColor : Color(.systemGray4))
                        .frame(width: 10, height: 10)
                    Text(label).font(.system(size: 9)).foregroundColor(.secondary)
                }
                if p != .summary {
                    Rectangle()
                        .fill(order(p) < order(phase) ? Color.accentColor : Color(.systemGray4))
                        .frame(height: 2)
                        .padding(.bottom, 14)
                }
            }
        }
    }
}

// MARK: - Global Stat Chip

private struct GlobalStatChip: View {
    let count: Int; let label: String; let color: Color
    var body: some View {
        VStack(spacing: 2) {
            Text("\(count)").font(.title3).bold().foregroundColor(color)
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Summary Row

private struct SumRow: View {
    let label: String; let value: Int; let icon: String; let color: Color
    var body: some View {
        HStack {
            Label(label, systemImage: icon).foregroundColor(color)
            Spacer()
            Text("\(value)").font(.headline).foregroundColor(color)
        }
    }
}

// MARK: - DTO Types (Edge Function response)

private struct EdgeFunctionResponse: Decodable {
    let success: Bool
    let tabCount: Int
    let totalRows: Int
    let tabs: [String: ParsedTabDTO]
}

private struct ParsedTabDTO: Decodable {
    let recordType: String
    let sheetName: String
    let rows: [ParsedRowDTO]
    let rowCount: Int
}

struct ParsedRowDTO: Decodable {
    let rowIndex: Int
    let data: [String: String]
    let companyMismatch: Bool?
}

// MARK: - Error Types

enum ImportParseError: LocalizedError {
    case serverError(String)
    var errorDescription: String? {
        switch self { case .serverError(let m): return "Server error: \(m)" }
    }
}

// MARK: - AppStore session helper

extension AppStore {
    /// Returns current Supabase session for API calls.
    func supabaseSession() async throws -> (accessToken: String, userID: UUID) {
        guard let user = currentUser else { throw URLError(.userAuthenticationRequired) }
        // Access token from SupabaseService
        let token = try await AuthService.currentAccessToken()
        return (token, user.id)
    }
}
