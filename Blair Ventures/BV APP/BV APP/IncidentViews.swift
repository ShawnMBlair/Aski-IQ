// IncidentViews.swift
// BV APP – Incident Reporting UI

import SwiftUI
import PhotosUI
import CryptoKit
import UniformTypeIdentifiers

// MARK: - Incident List View

struct IncidentListView: View {
    @EnvironmentObject var store: AppStore
    @State private var searchText    = ""
    @State private var filterType:     IncidentType?     = nil
    @State private var filterSeverity: IncidentSeverity? = nil
    @State private var filterStatus:   IncidentStatus?   = nil
    @State private var showCreate      = false
    @StateObject private var pagination = PaginationState(pageSize: 25)

    private var filtered: [Incident] {
        store.incidents
            .filter { filterType     == nil || $0.incidentType == filterType }
            .filter { filterSeverity == nil || $0.severity     == filterSeverity }
            .filter { filterStatus   == nil || $0.status       == filterStatus }
            .filter {
                searchText.isEmpty ||
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.reportedByName.localizedCaseInsensitiveContains(searchText) ||
                ($0.locationDescription ?? "").localizedCaseInsensitiveContains(searchText)
            }
            .sorted { $0.incidentDate > $1.incidentDate }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // Filter bar
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(label: "All", isSelected: filterStatus == nil && filterSeverity == nil && filterType == nil) {
                            filterType = nil; filterSeverity = nil; filterStatus = nil
                        }
                        FilterChip(label: "Open", isSelected: filterStatus == .open) {
                            filterStatus = filterStatus == .open ? nil : .open
                        }
                        FilterChip(label: "🔴 Critical", isSelected: filterSeverity == .critical) {
                            filterSeverity = filterSeverity == .critical ? nil : .critical
                        }
                        FilterChip(label: "🟠 High", isSelected: filterSeverity == .high) {
                            filterSeverity = filterSeverity == .high ? nil : .high
                        }
                        Divider().frame(height: 20)
                        ForEach(IncidentType.allCases, id: \.self) { t in
                            FilterChip(label: t.displayName, isSelected: filterType == t) {
                                filterType = filterType == t ? nil : t
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }
                Divider()

                if filtered.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 52)).foregroundColor(.green)
                        Text("No incidents recorded.")
                            .font(.headline)
                        Text("Stay safe out there.")
                            .font(.subheadline).foregroundColor(.secondary)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(Array(filtered.prefix(pagination.displayLimit))) { incident in
                            NavigationLink {
                                IncidentDetailView(incident: incident)
                            } label: {
                                IncidentListRow(incident: incident)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.deleteIncident(incident)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        LoadMoreFooter(
                            showing: min(pagination.displayLimit, filtered.count),
                            total:   filtered.count,
                            onLoad:  { pagination.loadMore() }
                        )
                    }
                    .listStyle(.plain)
                    .onChange(of: searchText)      { _ in pagination.reset() }
                    .onChange(of: filterType)      { _ in pagination.reset() }
                    .onChange(of: filterSeverity)  { _ in pagination.reset() }
                    .onChange(of: filterStatus)    { _ in pagination.reset() }
                }
            }
            .searchable(text: $searchText, prompt: "Search incidents")
            .refreshable { await store.refreshAll() }
            .navigationTitle("Incidents")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showCreate = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showCreate) {
                IncidentCreateEditView()
            }
        }
    }
}

// MARK: - Incident List Row

struct IncidentListRow: View {
    let incident: Incident
    @EnvironmentObject var store: AppStore

    private var projectName: String? {
        incident.projectID.flatMap { store.project(id: $0) }?.name
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(incident.incidentType.color.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: incident.incidentType.icon)
                    .foregroundColor(incident.incidentType.color)
                    .font(.system(size: 18))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(incident.title)
                        .font(.subheadline).bold()
                        .lineLimit(1)
                    SeverityBadge(severity: incident.severity)
                }
                HStack(spacing: 6) {
                    Text(incident.incidentType.displayName)
                        .font(.caption).foregroundColor(.secondary)
                    if let proj = projectName {
                        Text("·").foregroundColor(.secondary).font(.caption)
                        Text(proj).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                Text(incident.reportedByName).font(.caption2).foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(incident.incidentDate.shortDate)
                    .font(.caption2).foregroundColor(.secondary)
                IncidentStatusBadge(status: incident.status)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Incident Detail View

struct IncidentDetailView: View {
    let incident: Incident
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var showEdit          = false
    @State private var showShareSheet    = false
    @State private var shareItems: [Any] = []
    @State private var isGeneratingPDF   = false
    @State private var showAISummary     = false

    private var projectName: String? {
        incident.projectID.flatMap { store.project(id: $0) }?.name
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Header card
                headerCard.padding(.horizontal)

                // AI Summary
                AISummarizeButton(text: incidentTextForAI, context: "incident report")
                    .padding(.horizontal)

                // Legal certification
                if incident.isSigned {
                    certBanner.padding(.horizontal)
                }

                // Details sections
                detailSection(title: "Description", content: incident.description)

                if let ia = incident.immediateActions, !ia.isEmpty {
                    detailSection(title: "Immediate Actions Taken", content: ia)
                }
                if let rc = incident.rootCause, !rc.isEmpty {
                    detailSection(title: "Root Cause", content: rc)
                }
                if let ca = incident.correctiveActions, !ca.isEmpty {
                    detailSection(title: "Corrective Actions", content: ca)
                }

                // Witnesses
                if !incident.witnesses.isEmpty {
                    infoCard(title: "Witnesses") {
                        ForEach(incident.witnesses, id: \.self) { w in
                            Label(w, systemImage: "person").font(.subheadline)
                        }
                    }
                }

                // Injury details
                if incident.incidentType == .firstAid || incident.incidentType == .medicalAid || incident.incidentType == .lostTime {
                    injuryCard
                }

                // Regulatory
                if incident.reportableToWCB || incident.reportableToOHS {
                    regulatoryCard
                }

                // Photos
                if !incident.photoData.isEmpty {
                    photoGrid
                }

                // Attached Documents
                if !incident.documentAttachments.isEmpty {
                    attachedDocumentsSection
                }

                Spacer(minLength: 40)
            }
            .padding(.top)
        }
        .navigationTitle(incident.incidentType.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    Button {
                        showAISummary = true
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    if isGeneratingPDF {
                        ProgressView().tint(.blue)
                    } else {
                        Button {
                            exportPDF()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    Button("Edit") { showEdit = true }
                }
            }
        }
        .sheet(isPresented: $showEdit) {
            IncidentCreateEditView(existing: incident)
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        .sheet(isPresented: $showAISummary) {
            AISummarySheet(
                documentText: incidentTextForAI,
                contextLabel: "incident report"
            )
        }
    }

    private var incidentTextForAI: String {
        var parts: [String] = [
            "Incident: \(incident.title)",
            "Type: \(incident.incidentType.displayName)",
            "Severity: \(incident.severity.displayName)",
            "Status: \(incident.status.displayName)",
            "Date: \(incident.incidentDate.formatted(date: .long, time: .omitted))",
            "Reported by: \(incident.reportedByName)",
            "Description: \(incident.description)"
        ]
        if let ia = incident.immediateActions { parts.append("Immediate Actions: \(ia)") }
        if let rc = incident.rootCause { parts.append("Root Cause: \(rc)") }
        if let ca = incident.correctiveActions { parts.append("Corrective Actions: \(ca)") }
        if !incident.witnesses.isEmpty { parts.append("Witnesses: \(incident.witnesses.joined(separator: ", "))") }
        return parts.joined(separator: "\n")
    }

    // MARK: Header Card

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(incident.title).font(.title3).bold()
                    HStack(spacing: 8) {
                        SeverityBadge(severity: incident.severity)
                        IncidentStatusBadge(status: incident.status)
                    }
                }
                Spacer()
                ZStack {
                    Circle().fill(incident.incidentType.color.opacity(0.15)).frame(width: 52, height: 52)
                    Image(systemName: incident.incidentType.icon)
                        .font(.title2).foregroundColor(incident.incidentType.color)
                }
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow {
                    metaCell(label: "Type",     value: incident.incidentType.displayName)
                    metaCell(label: "Date",     value: incident.incidentDate.formatted(date: .abbreviated, time: .omitted))
                }
                GridRow {
                    metaCell(label: "Reported By", value: incident.reportedByName)
                    metaCell(label: "Time",        value: incident.incidentTime.formatted(date: .omitted, time: .shortened))
                }
                if let proj = projectName {
                    GridRow {
                        metaCell(label: "Project",  value: proj)
                        metaCell(label: "Location", value: incident.locationDescription ?? "—")
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }

    private func metaCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundColor(.secondary).textCase(.uppercase)
            Text(value).font(.subheadline)
        }
    }

    // MARK: Legal Banner

    private var certBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "lock.shield.fill").foregroundColor(.green).font(.headline)
                Text("Certified Incident Report").font(.headline).foregroundColor(.green)
                Spacer()
                Image(systemName: "checkmark.seal.fill").foregroundColor(.green).font(.title3)
            }
            Divider()
            if let hash = incident.auditHash {
                Text(String(hash.prefix(32)) + "…")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 20) {
                if let by = incident.signedBy {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SIGNED BY").font(.caption2).bold().foregroundColor(.secondary)
                        Text(by).font(.caption)
                    }
                }
                if let at = incident.signedAt {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SIGNED AT").font(.caption2).bold().foregroundColor(.secondary)
                        Text(at.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.green.opacity(0.05))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.green.opacity(0.3), lineWidth: 1))
        .cornerRadius(12)
    }

    // MARK: Injury Card

    private var injuryCard: some View {
        infoCard(title: "Injury / Medical Details") {
            if let name = incident.injuredPersonName {
                IncidentLabeledRow(label: "Injured Person", value: name)
            }
            if let desc = incident.injuryDescription {
                IncidentLabeledRow(label: "Injury", value: desc)
            }
            if let tx = incident.medicalTreatment {
                IncidentLabeledRow(label: "Treatment", value: tx)
            }
            if let days = incident.workDaysLost {
                IncidentLabeledRow(label: "Days Lost", value: "\(days)")
            }
        }
    }

    // MARK: Regulatory Card

    private var regulatoryCard: some View {
        infoCard(title: "Regulatory Reporting") {
            if incident.reportableToWCB {
                HStack {
                    Label("WCB Reportable", systemImage: "checkmark.circle.fill").foregroundColor(.orange)
                    Spacer()
                    if let claim = incident.wcbClaimNumber {
                        Text("Claim: \(claim)").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            if incident.reportableToOHS {
                Label("OHS Reportable", systemImage: "checkmark.circle.fill").foregroundColor(.red)
            }
        }
    }

    // MARK: Photo Grid

    private var photoGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Photos", count: incident.photoData.count)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(incident.photoData.enumerated()), id: \.offset) { _, data in
                        if let img = UIImage(data: data) {
                            Image(uiImage: img)
                                .resizable().scaledToFill()
                                .frame(width: 120, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: Attached Documents

    private var attachedDocumentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Attached Documents", count: incident.documentAttachments.count)
            VStack(spacing: 0) {
                ForEach(incident.documentAttachments) { doc in
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.red.opacity(0.1))
                                .frame(width: 36, height: 36)
                            Image(systemName: "doc.fill")
                                .foregroundColor(.red)
                                .font(.system(size: 15))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.fileName)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(doc.fileData.count), countStyle: .file))
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button {
                            shareIncidentDoc(doc)
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundColor(.blue)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal)
                    if doc.id != incident.documentAttachments.last?.id { Divider().padding(.leading, 60) }
                }
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }

    // MARK: Share Document

    private func shareIncidentDoc(_ doc: IncidentDocument) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(doc.fileName)
        try? doc.fileData.write(to: url)
        shareItems = [url]
        showShareSheet = true
    }

    // MARK: Helpers

    private func detailSection(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title)
            Text(content)
                .font(.subheadline)
                .foregroundColor(.primary)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)
        }
    }

    private func infoCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }

    // MARK: PDF Export

    private func exportPDF() {
        isGeneratingPDF = true
        Task.detached(priority: .userInitiated) {
            let pdfData = IncidentPDFRenderer(
                incident:    incident,
                projectName: await MainActor.run { projectName },
                company:     "Aski IQ"
            ).render()
            let safeName = incident.title
                .components(separatedBy: .whitespacesAndNewlines).joined(separator: "_")
            let shortID  = incident.id.uuidString.prefix(8).uppercased()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Incident_\(safeName)_\(shortID).pdf")
            try? pdfData.write(to: url)
            await MainActor.run {
                shareItems      = [url]
                isGeneratingPDF = false
                showShareSheet  = true
            }
        }
    }
}

// MARK: - Incident Create / Edit View

struct IncidentCreateEditView: View {
    var existing: Incident? = nil
    var prelinkedProjectID: UUID? = nil   // pre-selects project when opened from ProjectDetailView
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    // Core
    @State private var title            = ""
    @State private var incidentType:     IncidentType     = .nearMiss
    @State private var severity:         IncidentSeverity = .medium
    @State private var status:           IncidentStatus   = .open
    @State private var selectedProjectID: UUID?           = nil
    @State private var incidentDate      = Date()
    @State private var incidentTime      = Date()
    @State private var locationDesc      = ""

    // Description
    @State private var description       = ""
    @State private var immediateActions  = ""
    @State private var rootCause         = ""
    @State private var correctiveActions = ""
    @State private var witnessText       = ""   // comma-separated

    // Injury
    @State private var injuredName       = ""
    @State private var injuryDesc        = ""
    @State private var medicalTreatment  = ""
    @State private var workDaysLost      = ""

    // Regulatory
    @State private var reportWCB         = false
    @State private var wcbClaim          = ""
    @State private var reportOHS         = false

    // Photos
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var photoData:  [Data]             = []

    // Documents
    @State private var documentAttachments: [IncidentDocument] = []
    @State private var showDocumentPicker = false

    // Signature
    @State private var isSigned          = false
    @State private var signerName        = ""
    @State private var signatureImage:   UIImage?    = nil
    @State private var showSigCanvas     = false

    @State private var showValidation    = false
    @State private var validationMsg     = ""

    private var isEditing: Bool { existing != nil }

    var body: some View {
        NavigationStack {
            Form {

                // MARK: Core
                Section("Incident Details *") {
                    TextField("Incident title / summary", text: $title)
                    Picker("Type", selection: $incidentType) {
                        ForEach(IncidentType.allCases, id: \.self) {
                            Label($0.displayName, systemImage: $0.icon).tag($0)
                        }
                    }
                    Picker("Severity", selection: $severity) {
                        ForEach(IncidentSeverity.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    Picker("Status", selection: $status) {
                        ForEach(IncidentStatus.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                }

                // MARK: Where / When
                Section("Time & Location") {
                    DatePicker("Date", selection: $incidentDate, displayedComponents: .date)
                    DatePicker("Time", selection: $incidentTime, displayedComponents: .hourAndMinute)
                    TextField("Location on site (e.g. North yard, Scaffold Level 3)", text: $locationDesc)
                    if !store.projects.isEmpty {
                        Picker("Project", selection: $selectedProjectID) {
                            Text("None").tag(UUID?.none)
                            ForEach(store.projects.filter { $0.status == .active }) { p in
                                Text(p.name).tag(Optional(p.id))
                            }
                        }
                    }
                }

                // MARK: Description
                Section("What Happened *") {
                    TextEditor(text: $description).frame(minHeight: 80)
                }

                Section("Immediate Actions Taken") {
                    TextEditor(text: $immediateActions).frame(minHeight: 60)
                }

                Section("Root Cause Analysis") {
                    TextEditor(text: $rootCause).frame(minHeight: 60)
                }

                Section("Corrective Actions") {
                    TextEditor(text: $correctiveActions).frame(minHeight: 60)
                }

                Section {
                    TextField("Witness names (comma separated)", text: $witnessText)
                } header: {
                    Text("Witnesses")
                }

                // MARK: Injury (conditional)
                if incidentType == .firstAid || incidentType == .medicalAid || incidentType == .lostTime {
                    Section("Injury Details") {
                        TextField("Injured person's name", text: $injuredName)
                        TextField("Nature of injury", text: $injuryDesc)
                        TextField("Medical treatment provided", text: $medicalTreatment)
                        HStack {
                            Text("Days lost")
                            Spacer()
                            TextField("0", text: $workDaysLost)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 60)
                        }
                    }
                }

                // MARK: Regulatory
                Section("Regulatory") {
                    Toggle("Reportable to WCB", isOn: $reportWCB)
                    if reportWCB {
                        TextField("WCB Claim #", text: $wcbClaim)
                    }
                    Toggle("Reportable to OHS", isOn: $reportOHS)
                }

                // MARK: Photos
                Section("Site Photos") {
                    PhotosPicker(selection: $photoItems, maxSelectionCount: 10,
                                 matching: .images) {
                        Label("Add Photos (\(photoData.count) selected)", systemImage: "camera")
                            .foregroundColor(.blue)
                    }
                    .onChange(of: photoItems) { items in
                        Task {
                            var loaded: [Data] = []
                            for item in items {
                                if let data = try? await item.loadTransferable(type: Data.self) {
                                    loaded.append(compressPhoto(data))
                                }
                            }
                            photoData = loaded
                        }
                    }
                    if !photoData.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(photoData.enumerated()), id: \.offset) { _, data in
                                    if let img = UIImage(data: data) {
                                        Image(uiImage: img)
                                            .resizable().scaledToFill()
                                            .frame(width: 80, height: 80)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                // MARK: Documents
                Section("Attached Documents") {
                    Button {
                        showDocumentPicker = true
                    } label: {
                        Label("Attach PDF / Document", systemImage: "doc.badge.plus")
                            .foregroundColor(.blue)
                    }
                    ForEach(documentAttachments) { doc in
                        HStack(spacing: 10) {
                            Image(systemName: "doc.fill").foregroundColor(.red)
                            Text(doc.fileName)
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                documentAttachments.removeAll { $0.id == doc.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                // MARK: Signature
                Section {
                    TextField("Reported by (name)", text: $signerName)
                    if isSigned, let img = signatureImage {
                        VStack(spacing: 6) {
                            Image(uiImage: img)
                                .resizable().scaledToFit()
                                .frame(maxHeight: 80)
                                .padding(4)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(8)
                            HStack {
                                Text("Signed").font(.caption).foregroundColor(.green)
                                Spacer()
                                Button("Clear") { isSigned = false; signatureImage = nil }
                                    .font(.caption).foregroundColor(.red)
                            }
                        }
                    } else {
                        Button {
                            showSigCanvas = true
                        } label: {
                            Label("Draw Signature", systemImage: "signature")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color.blue.opacity(0.08))
                                .foregroundColor(.blue)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Signature / Certification")
                }

                // MARK: Delete
                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            if let e = existing { store.deleteIncident(e); dismiss() }
                        } label: {
                            Label("Delete Incident", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Incident" : "Report Incident")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }.bold()
                }
            }
            .alert("Missing Info", isPresented: $showValidation) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationMsg)
            }
            .sheet(isPresented: $showSigCanvas) {
                SignatureCanvasSheet { img in
                    signatureImage = img
                    isSigned = img != nil
                }
            }
            .fileImporter(
                isPresented: $showDocumentPicker,
                allowedContentTypes: [.pdf, .data, UTType("com.microsoft.word.doc") ?? .data],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    for url in urls {
                        guard url.startAccessingSecurityScopedResource() else { continue }
                        defer { url.stopAccessingSecurityScopedResource() }
                        if let data = try? Data(contentsOf: url) {
                            documentAttachments.append(IncidentDocument(
                                fileName: url.lastPathComponent,
                                fileData: data
                            ))
                        }
                    }
                case .failure:
                    break
                }
            }
            .onAppear { populate() }
        }
    }

    // MARK: Populate (edit mode)

    private func populate() {
        // Pre-link project when opened from ProjectDetailView
        if existing == nil, let pid = prelinkedProjectID {
            selectedProjectID = pid
        }
        guard let e = existing else { return }
        title             = e.title
        incidentType      = e.incidentType
        severity          = e.severity
        status            = e.status
        selectedProjectID = e.projectID
        incidentDate      = e.incidentDate
        incidentTime      = e.incidentTime
        locationDesc      = e.locationDescription ?? ""
        description       = e.description
        immediateActions  = e.immediateActions ?? ""
        rootCause         = e.rootCause ?? ""
        correctiveActions = e.correctiveActions ?? ""
        witnessText       = e.witnesses.joined(separator: ", ")
        injuredName       = e.injuredPersonName ?? ""
        injuryDesc        = e.injuryDescription ?? ""
        medicalTreatment  = e.medicalTreatment ?? ""
        workDaysLost      = e.workDaysLost.map { "\($0)" } ?? ""
        reportWCB         = e.reportableToWCB
        wcbClaim          = e.wcbClaimNumber ?? ""
        reportOHS         = e.reportableToOHS
        photoData             = e.photoData
        documentAttachments   = e.documentAttachments
        isSigned              = e.isSigned
        signerName            = e.signedBy ?? ""
    }

    // MARK: Save

    private func save() {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationMsg = "Incident title is required."; showValidation = true; return
        }
        guard !description.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationMsg = "Description is required."; showValidation = true; return
        }

        var incident       = existing ?? Incident(title: title)
        incident.title     = title
        incident.incidentType      = incidentType
        incident.severity          = severity
        incident.status            = status
        incident.projectID         = selectedProjectID
        incident.incidentDate      = incidentDate
        incident.incidentTime      = incidentTime
        incident.locationDescription = locationDesc.isEmpty ? nil : locationDesc
        incident.description       = description
        incident.immediateActions  = immediateActions.isEmpty  ? nil : immediateActions
        incident.rootCause         = rootCause.isEmpty         ? nil : rootCause
        incident.correctiveActions = correctiveActions.isEmpty ? nil : correctiveActions
        incident.witnesses         = witnessText.isEmpty ? [] : witnessText
            .components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        incident.injuredPersonName  = injuredName.isEmpty     ? nil : injuredName
        incident.injuryDescription  = injuryDesc.isEmpty      ? nil : injuryDesc
        incident.medicalTreatment   = medicalTreatment.isEmpty ? nil : medicalTreatment
        incident.workDaysLost       = Int(workDaysLost)
        incident.reportableToWCB    = reportWCB
        incident.wcbClaimNumber     = wcbClaim.isEmpty ? nil : wcbClaim
        incident.reportableToOHS    = reportOHS
        incident.photoData          = photoData
        incident.documentAttachments = documentAttachments
        incident.reportedByName     = signerName.isEmpty
            ? (store.currentUser?.fullName ?? "") : signerName
        incident.reportedByID       = store.currentUser?.id

        if isSigned {
            incident.isSigned  = true
            incident.signedBy  = signerName.isEmpty ? store.currentUser?.fullName : signerName
            incident.signedAt  = Date()
            incident.auditHash = IncidentAuditService.generateHash(for: incident)
        }

        incident.lastModifiedBy = store.currentUser?.fullName ?? ""
        incident.lastModifiedAt = Date()
        incident.updatedAt      = Date()

        store.upsertIncident(incident)
        dismiss()
    }
}

// MARK: - Shared Badge Views

struct SeverityBadge: View {
    let severity: IncidentSeverity
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: severity.icon).font(.caption2)
            Text(severity.displayName).font(.caption2).bold()
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(severity.color.opacity(0.15))
        .foregroundColor(severity.color)
        .cornerRadius(5)
    }
}

struct IncidentStatusBadge: View {
    let status: IncidentStatus
    var body: some View {
        Text(status.displayName)
            .font(.caption2).bold()
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(status.color.opacity(0.15))
            .foregroundColor(status.color)
            .cornerRadius(5)
    }
}

// MARK: - Labeled Row

private struct IncidentLabeledRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).font(.subheadline).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.subheadline)
        }
    }
}

// MARK: - Audit Hash Service

enum IncidentAuditService {
    static func generateHash(for incident: Incident) -> String {
        var input = Data()
        input += incident.id.uuidString.data(using: .utf8) ?? Data()
        input += incident.title.data(using: .utf8) ?? Data()
        input += incident.description.data(using: .utf8) ?? Data()
        input += incident.reportedByName.data(using: .utf8) ?? Data()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        input += iso.string(from: incident.incidentDate).data(using: .utf8) ?? Data()
        return SHA256.hash(data: input)
            .compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Incident PDF Renderer

final class IncidentPDFRenderer {
    private let incident:    Incident
    private let projectName: String?
    private let company:     String

    private let pageW:  CGFloat = 612
    private let pageH:  CGFloat = 792
    private let margin: CGFloat = 44
    private var cW:     CGFloat { pageW - 2 * margin }
    private var posY:   CGFloat = 0
    private var ctx:    UIGraphicsPDFRendererContext!

    private let clrBlue  = UIColor(red: 0.11, green: 0.39, blue: 0.84, alpha: 1.0)
    private let clrDark  = UIColor(white: 0.13, alpha: 1)
    private let clrMid   = UIColor(white: 0.44, alpha: 1)
    private let clrRed   = UIColor.systemRed

    init(incident: Incident, projectName: String?, company: String) {
        self.incident    = incident
        self.projectName = projectName
        self.company     = company
    }

    func render() -> Data {
        let bounds = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { c in
            self.ctx = c
            c.beginPage()
            posY = margin
            drawHeader()
            drawSection("DESCRIPTION",         text: incident.description)
            if let ia = incident.immediateActions,  !ia.isEmpty { drawSection("IMMEDIATE ACTIONS", text: ia) }
            if let rc = incident.rootCause,          !rc.isEmpty { drawSection("ROOT CAUSE",       text: rc) }
            if let ca = incident.correctiveActions,  !ca.isEmpty { drawSection("CORRECTIVE ACTIONS", text: ca) }
            if !incident.witnesses.isEmpty {
                drawSection("WITNESSES", text: incident.witnesses.joined(separator: "  ·  "))
            }
            drawCertFooter()
        }
    }

    private func drawHeader() {
        let fCo  = UIFont.systemFont(ofSize: 18, weight: .heavy)
        let fTit = UIFont.systemFont(ofSize: 13, weight: .bold)
        let fLbl = UIFont.systemFont(ofSize: 8.5, weight: .semibold)
        let fVal = UIFont.systemFont(ofSize: 8.5, weight: .regular)

        put(company.uppercased(), font: fCo, color: clrBlue, x: margin, y: posY, w: cW - 100, h: 26)

        // Severity badge (top right)
        let sevColor: UIColor
        switch incident.severity {
        case .low:      sevColor = .systemGreen
        case .medium:   sevColor = .systemYellow
        case .high:     sevColor = .systemOrange
        case .critical: sevColor = .systemRed
        }
        drawBadge(incident.severity.displayName.uppercased(), color: sevColor, rightX: pageW - margin, topY: posY + 4)
        posY += 30

        put("INCIDENT REPORT", font: UIFont.systemFont(ofSize: 9, weight: .bold), color: clrMid,
            x: margin, y: posY, w: cW, h: 12)
        posY += 14
        put(incident.title, font: fTit, color: clrDark, x: margin, y: posY, w: cW, h: 20)
        posY += 26

        let df = DateFormatter(); df.dateStyle = .long; df.timeStyle = .short
        let meta: [(String, String)] = [
            ("Type",         incident.incidentType.displayName),
            ("Date / Time",  df.string(from: incident.incidentDate)),
            ("Reported By",  incident.reportedByName),
            ("Project",      projectName ?? "—"),
            ("Location",     incident.locationDescription ?? "—"),
            ("Status",       incident.status.displayName),
        ]
        let lw: CGFloat = 72
        for (lbl, val) in meta {
            put(lbl + ":", font: fLbl, color: clrMid,  x: margin, y: posY, w: lw, h: 13)
            put(val,       font: fVal, color: clrDark,  x: margin + lw + 4, y: posY, w: cW - lw - 4, h: 13)
            posY += 13
        }
        posY += 8
        hr(thick: true)
    }

    private func drawSection(_ heading: String, text: String) {
        let fSec = UIFont.systemFont(ofSize: 9, weight: .bold)
        let fVal = UIFont.systemFont(ofSize: 9, weight: .regular)
        let h    = textH(text, width: cW, font: fVal)
        ensureSpace(h + 30)
        posY += 6
        put(heading, font: fSec, color: clrBlue, x: margin, y: posY, w: cW, h: 13)
        posY += 16
        putWrap(text, font: fVal, color: clrDark, x: margin, y: posY, w: cW, h: h + 4)
        posY += h + 10
        hr(thick: false)
    }

    private func drawCertFooter() {
        ensureSpace(100)
        posY += 10
        hr(thick: true)
        put("DOCUMENT CERTIFICATION", font: UIFont.systemFont(ofSize: 9, weight: .bold),
            color: clrBlue, x: margin, y: posY, w: cW, h: 13)
        posY += 16

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rows: [(String, String)] = [
            ("Incident ID", incident.id.uuidString.uppercased()),
            ("Reported",    iso.string(from: incident.incidentDate)),
            ("SHA-256",     incident.auditHash ?? "Not yet signed"),
        ]
        let lw: CGFloat = 72
        for (k, v) in rows {
            let fMon = UIFont.monospacedSystemFont(ofSize: 7.5, weight: .regular)
            let vH = textH(v, width: cW - lw - 6, font: fMon)
            ensureSpace(max(14, vH + 4))
            put(k + ":", font: UIFont.systemFont(ofSize: 8, weight: .semibold), color: clrMid,
                x: margin, y: posY, w: lw, h: 14)
            putWrap(v, font: fMon, color: clrDark, x: margin + lw + 6, y: posY, w: cW - lw - 6, h: vH + 4)
            posY += max(14, vH + 4) + 1
        }
        posY += 6
        hr(thick: true)
        let now = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        put("Generated: \(now)  ·  Aski IQ",
            font: UIFont.systemFont(ofSize: 7.5, weight: .regular), color: clrMid,
            x: margin, y: posY + 4, w: cW, h: 12)
    }

    // MARK: Primitives

    private func put(_ text: String, font: UIFont, color: UIColor,
                     x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        (text as NSString).draw(in: CGRect(x: x, y: y, width: w, height: h),
                                withAttributes: [.font: font, .foregroundColor: color])
    }

    private func putWrap(_ text: String, font: UIFont, color: UIColor,
                         x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byWordWrapping
        (text as NSString).draw(in: CGRect(x: x, y: y, width: w, height: h + 12),
                                withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
    }

    private func hr(thick: Bool) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: margin, y: posY))
        path.addLine(to: CGPoint(x: pageW - margin, y: posY))
        clrBlue.withAlphaComponent(thick ? 1 : 0.25).setStroke()
        path.lineWidth = thick ? 1.5 : 0.4; path.stroke()
        posY += thick ? 8 : 4
    }

    private func drawBadge(_ text: String, color: UIColor, rightX: CGFloat, topY: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 7.5, weight: .bold), .foregroundColor: UIColor.white
        ]
        let sz = (text as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 5
        let rect = CGRect(x: rightX - sz.width - pad * 2, y: topY, width: sz.width + pad * 2, height: 16)
        color.setFill(); UIBezierPath(roundedRect: rect, cornerRadius: 4).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + pad, y: rect.minY + 2.5), withAttributes: attrs)
    }

    private func textH(_ text: String, width: CGFloat, font: UIFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byWordWrapping
        return ceil((text as NSString).boundingRect(
            with: CGSize(width: width, height: 5000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: para], context: nil).height)
    }

    private func ensureSpace(_ needed: CGFloat) {
        if posY + needed > pageH - margin - 12 { ctx.beginPage(); posY = margin }
    }
}
