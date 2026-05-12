// FormSubmissionViews.swift
// FieldOS – Form Submission (Full Form Builder)

import SwiftUI
import PhotosUI
import CoreLocation

// MARK: - Form Submission View

struct FormSubmissionView: View {
    let template: FormTemplate
    var projectID: UUID? = nil
    var isPreview: Bool = false

    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    @State private var responses: [UUID: FormFieldResponse] = [:]
    @State private var signatureImage: UIImage? = nil
    @State private var signerName = ""
    @State private var isSigned = false
    @State private var showSignatureCanvas = false
    @State private var workerSignatures: [WorkerSignature] = []
    @State private var workerSigningID: UUID? = nil
    @State private var showWorkerSigCanvas = false
    @State private var showValidationError = false
    @State private var validationMessage = ""
    @State private var showSuccess = false
    @State private var firstErrorFieldID: UUID? = nil

    // Link To
    @State private var linkType: FormLinkType = .none
    @State private var linkedProjectID: UUID? = nil
    @State private var linkedName: String = ""
    @State private var linkedAddress: String = ""
    @State private var linkedCoordinate: LocationResponse? = nil
    @State private var showLinkCoordinateCapture = false

    private var visibleFields: [FormField] {
        template.orderedFields
            .filter { field in
                guard let condition = field.condition else { return true }
                return evaluateCondition(condition)
            }
    }

    private var workerSignatureEligible: [Employee] {
        let pid = linkedProjectID ?? projectID
        guard let pid else { return [] }
        let crewMemberIDs = store.crews
            .filter { c in store.scheduleEntries.contains { $0.projectID == pid && $0.crewID == c.id } }
            .flatMap { $0.memberIDs }
        return store.employees.filter { crewMemberIDs.contains($0.id) && $0.isActive }
    }

    private func populateWorkerSignatures() {
        let eligible = workerSignatureEligible
        if !eligible.isEmpty && workerSignatures.isEmpty {
            workerSignatures = eligible.map {
                WorkerSignature(employeeID: $0.id, employeeName: $0.fullName)
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    // Form description
                    if let desc = template.formDescription, !desc.isEmpty {
                        Section {
                            Text(desc)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }

                    // Preview banner
                    if isPreview {
                        Section {
                            Label("Preview Mode — responses won't be saved", systemImage: "eye")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }

                    // Link To card
                    if !isPreview {
                        linkToSection
                    }

                    // Render fields, pairing consecutive half-width ones side-by-side
                    let rows = buildRows(from: visibleFields)
                    ForEach(rows.indices, id: \.self) { idx in
                        let row = rows[idx]
                        if row.count == 2 {
                            // Two half-width fields in one Form section row
                            Section {
                                HStack(alignment: .top, spacing: 16) {
                                    ForEach(row) { field in
                                        VStack(alignment: .leading, spacing: 4) {
                                            halfFieldHeader(field)
                                            FieldResponseView(
                                                field: field,
                                                response: responseBinding(for: field),
                                                highlightError: firstErrorFieldID == field.id
                                            )
                                            .id(field.id)
                                        }
                                        .frame(maxWidth: .infinity)
                                    }
                                }
                            }
                        } else if let field = row.first {
                            fieldSection(field, proxy: proxy)
                                .id(field.id)
                        }
                    }

                    // Signature
                    if template.requiresSignature {
                        Section {
                            signatureSection
                        } header: {
                            Text("Signature *")
                        }
                    }

                    // Worker Sign-offs (only when linked to a project with crew members)
                    let projectCrewMembers = workerSignatureEligible
                    if !projectCrewMembers.isEmpty {
                        Section {
                            ForEach($workerSignatures) { $ws in
                                HStack(spacing: 12) {
                                    ZStack {
                                        Circle()
                                            .fill(ws.isSigned ? Color.green.opacity(0.12) : Color.gray.opacity(0.1))
                                            .frame(width: 36, height: 36)
                                        Image(systemName: ws.isSigned ? "checkmark.seal.fill" : "person")
                                            .foregroundColor(ws.isSigned ? .green : .secondary)
                                            .font(.system(size: 14))
                                    }
                                    Text(ws.employeeName).font(.subheadline)
                                    Spacer()
                                    if ws.isSigned {
                                        Text("Signed").font(.caption2).bold()
                                            .padding(.horizontal, 6).padding(.vertical, 3)
                                            .background(Color.green.opacity(0.12)).foregroundColor(.green)
                                            .cornerRadius(4)
                                    } else {
                                        Button("Sign") {
                                            workerSigningID = ws.employeeID
                                            showWorkerSigCanvas = true
                                        }
                                        .font(.subheadline).foregroundColor(.blue)
                                    }
                                }
                            }
                        } header: {
                            Text("Worker Sign-offs")
                        } footer: {
                            Text("Select workers on this project to collect their signatures.")
                        }
                    }
                }
                .navigationTitle(template.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(isPreview ? "Close" : "Save Draft") {
                            if isPreview { dismiss() } else { saveDraft() }
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        if !isPreview {
                            Button("Submit") { submit(proxy: proxy) }
                                .bold()
                                .foregroundColor(.green)
                        }
                    }
                }
                .alert("Missing Info", isPresented: $showValidationError) {
                    Button("OK", role: .cancel) {}
                } message: { Text(validationMessage) }
                .alert("Submitted ✓", isPresented: $showSuccess) {
                    Button("Done") { dismiss() }
                } message: { Text("Form submitted successfully.") }
                .sheet(isPresented: $showSignatureCanvas) {
                    SignatureCanvasSheet { img in
                        signatureImage = img
                        isSigned = img != nil
                    }
                }
                .sheet(isPresented: $showWorkerSigCanvas) {
                    SignatureCanvasSheet { img in
                        if let wid = workerSigningID,
                           let idx = workerSignatures.firstIndex(where: { $0.employeeID == wid }),
                           let img = img,
                           let data = img.pngData() {
                            workerSignatures[idx].signatureData = data
                            workerSignatures[idx].signedAt = Date()
                            workerSignatures[idx].isSigned = true
                        }
                        workerSigningID = nil
                    }
                }
                .onAppear {
                    WeatherService.shared.fetchIfNeeded()
                    autoPopulate()
                    populateWorkerSignatures()
                }
                .onChange(of: store.currentWeather) {
                    // Re-run auto-populate when weather arrives after form opens
                    autoPopulate()
                }
            }
        }
    }

    // MARK: - Field Section Builder

    @ViewBuilder
    private func fieldSection(_ field: FormField, proxy: ScrollViewProxy) -> some View {
        switch field.type {

        case .sectionHeader:
            // Section headers render as a bold divider, not a Form section
            Section {
                HStack {
                    Rectangle()
                        .fill(Color.blue.opacity(0.5))
                        .frame(width: 3)
                    Text(field.label)
                        .font(.headline)
                        .padding(.leading, 6)
                    Spacer()
                }
                .listRowBackground(Color.blue.opacity(0.05))
            }

        case .instructions:
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    if !field.label.isEmpty {
                        Text(field.label).font(.subheadline).bold()
                    }
                    if let body = field.bodyText {
                        Text(body).font(.subheadline).foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.yellow.opacity(0.05))
            }

        default:
            Section {
                FieldResponseView(
                    field: field,
                    response: responseBinding(for: field),
                    highlightError: firstErrorFieldID == field.id
                )
                if let hint = field.hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                HStack(spacing: 4) {
                    Text(field.label)
                    if field.isRequired {
                        Text("*").foregroundColor(.red)
                    }
                }
            }
        }
    }

    // MARK: - Link To Section

    private var linkToSection: some View {
        Section {
            // Type picker row
            HStack(spacing: 0) {
                ForEach(FormLinkType.allCases, id: \.self) { type in
                    Button {
                        withAnimation { linkType = type }
                        // Auto-populate project name when switching to project
                        if type == .project, let pid = linkedProjectID ?? store.projects.first?.id {
                            linkedProjectID = pid
                            linkedName = store.projects.first { $0.id == pid }?.name ?? ""
                        }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: type.icon)
                                .font(.system(size: 13))
                            Text(type.displayName)
                                .font(.caption2)
                        }
                        .foregroundColor(linkType == type ? .white : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(linkType == type ? linkColor(type) : Color.clear)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color(.tertiarySystemBackground))
            .cornerRadius(10)

            // Detail input based on type
            switch linkType {
            case .none:
                EmptyView()

            case .project:
                if store.projects.isEmpty {
                    Text("No projects yet. Create one first.")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Picker("Project", selection: Binding(
                        get: { linkedProjectID ?? store.projects.first!.id },
                        set: { id in
                            linkedProjectID = id
                            if let proj = store.projects.first(where: { $0.id == id }) {
                                linkedName    = proj.name
                                linkedAddress = proj.siteAddress ?? ""
                                populateFromProject(proj)
                            }
                        }
                    )) {
                        ForEach(store.projects.filter { $0.status == .active }) { project in
                            Text(project.name).tag(project.id)
                        }
                    }
                    if let proj = store.projects.first(where: { $0.id == linkedProjectID }) {
                        VStack(alignment: .leading, spacing: 2) {
                            if let addr = proj.siteAddress, !addr.isEmpty {
                                Label(addr, systemImage: "mappin")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            if !proj.clientName.isEmpty {
                                Label(proj.clientName, systemImage: "building.2")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .padding(.top, 2)
                    }
                }

            case .site:
                TextField("Site name (e.g. Ft. McMurray Site 3)", text: $linkedName)
                TextField("Address (optional)", text: $linkedAddress)

            case .office:
                TextField("Office name (e.g. Edmonton Office)", text: $linkedName)
                TextField("Address (optional)", text: $linkedAddress)

            case .location:
                TextField("Location name (optional)", text: $linkedName)
                if let coord = linkedCoordinate {
                    HStack {
                        Image(systemName: "location.fill").foregroundColor(.green).font(.caption)
                        Text(String(format: "%.5f, %.5f", coord.latitude, coord.longitude))
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Button("Clear") { linkedCoordinate = nil }
                            .font(.caption).foregroundColor(.red)
                    }
                } else {
                    Button {
                        captureLocation()
                    } label: {
                        Label("Capture GPS Location", systemImage: "location")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.green.opacity(0.08))
                            .foregroundColor(.green)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "link").font(.caption)
                Text("Link To")
            }
        } footer: {
            if linkType != .none {
                Text(linkFooter)
                    .font(.caption2)
            }
        }
    }

    private func linkColor(_ type: FormLinkType) -> Color {
        switch type {
        case .none:     return .secondary
        case .project:  return .blue
        case .site:     return .orange
        case .office:   return .purple
        case .location: return .green
        }
    }

    private var linkFooter: String {
        switch linkType {
        case .project:  return "Form will appear in the selected project's form history."
        case .site:     return "Form will be tagged to this site name."
        case .office:   return "Form will be filed under this office."
        case .location: return "Form will be tagged to this GPS location."
        case .none:     return ""
        }
    }

    private func captureLocation() {
        LocationCapture.shared.requestOnce { result in
            if case .success(let loc) = result {
                linkedCoordinate = loc
            }
        }
    }

    // MARK: - Signature Section

    private var signatureSection: some View {
        Group {
            if isSigned, let img = signatureImage {
                VStack(spacing: 8) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 100)
                        .padding(4)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(8)
                    HStack {
                        if !signerName.isEmpty {
                            Text("Signed by \(signerName)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Clear") { isSigned = false; signatureImage = nil }
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    TextField("Signer name", text: $signerName)
                    Button {
                        showSignatureCanvas = true
                    } label: {
                        Label("Draw Signature", systemImage: "signature")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.blue.opacity(0.08))
                            .foregroundColor(.blue)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Response Binding

    private func responseBinding(for field: FormField) -> Binding<FormFieldResponse> {
        Binding(
            get: { responses[field.id] ?? FormFieldResponse(fieldID: field.id) },
            set: { responses[field.id] = $0 }
        )
    }

    // MARK: - Auto-Variable Population

    func autoPopulate() {
        let project = store.projects.first { $0.id == projectID }
        for field in template.fields {
            guard let variable = field.autoVariable else { continue }
            var r = responses[field.id] ?? FormFieldResponse(fieldID: field.id)
            switch variable {
            case .currentDate:
                r.dateValue = Date()
            case .currentTime:
                r.dateValue = Date()
            case .currentDateTime:
                r.dateValue = Date()
            case .userName:
                r.textValue = store.currentUser?.fullName ?? ""
            case .userRole:
                r.textValue = store.currentUserRole.rawValue.capitalized
            case .siteName:
                r.textValue = project?.name ?? ""
            case .siteAddress:
                r.textValue = project?.siteAddress ?? ""
            case .companyName:
                r.textValue = "Aski IQ"
            // Weather
            case .weatherCondition:
                r.textValue = store.currentWeather?.conditionText ?? ""
            case .weatherTemp:
                r.textValue = store.currentWeather?.tempString ?? ""
            case .weatherWind:
                r.textValue = store.currentWeather?.windString ?? ""
            case .weatherHumidity:
                r.textValue = store.currentWeather?.humidityString ?? ""
            case .weatherSummary:
                r.textValue = store.currentWeather?.summaryForForm ?? ""
            }
            // Only pre-fill if not already answered
            if responses[field.id] == nil {
                responses[field.id] = r
            }
        }
        // Also populate project-linked fields if a project was pre-selected
        if let proj = project {
            populateFromProject(proj, overwrite: false)
        }
    }

    // MARK: - Project Auto-Populate
    // Called when the user picks a project in the Link To section.
    // Fills any unanswered text fields that match by autoVariable or by label keyword.

    func populateFromProject(_ project: Project, overwrite: Bool = false) {
        let isText: (FormFieldType) -> Bool = { t in
            t == .shortText || t == .text || t == .longText
        }

        for field in template.fields {
            // Skip if already answered (unless forced)
            if !overwrite && responses[field.id] != nil { continue }

            var r     = FormFieldResponse(fieldID: field.id)
            var value = ""

            // 1. Match by autoVariable tag (highest priority)
            if let variable = field.autoVariable {
                switch variable {
                case .siteName:    value = project.name
                case .siteAddress: value = project.siteAddress ?? ""
                default: break
                }
            }

            // 2. Match by label keyword (text fields only)
            if value.isEmpty && isText(field.type) {
                let label = field.label.lowercased()
                if label.contains("project name") || label == "project" || label.contains("job name") {
                    value = project.name
                } else if label.contains("client") {
                    value = project.clientName
                } else if label.contains("site address") || (label.contains("address") && !label.contains("billing")) {
                    value = project.siteAddress ?? ""
                } else if label.contains("job number") || label.contains("job #") || label.contains("po number") || label.contains("po #") {
                    value = project.jobNumber ?? ""
                } else if label.contains("project manager") || label == "pm" || label.hasPrefix("pm ") {
                    value = project.assignedPMName ?? ""
                } else if label == "site" || label.hasPrefix("site name") {
                    value = project.name
                }
            }

            // Only write if we found something meaningful
            if !value.isEmpty {
                r.textValue       = value
                responses[field.id] = r
            }
        }
    }

    // MARK: - Row Builder (pairs consecutive half-width fields)

    private func buildRows(from fields: [FormField]) -> [[FormField]] {
        var rows: [[FormField]] = []
        var i = 0
        while i < fields.count {
            let current = fields[i]
            if current.columnWidth == .half,
               i + 1 < fields.count,
               fields[i + 1].columnWidth == .half,
               !current.type.isLayoutOnly,
               !fields[i + 1].type.isLayoutOnly {
                rows.append([current, fields[i + 1]])
                i += 2
            } else {
                rows.append([current])
                i += 1
            }
        }
        return rows
    }

    // MARK: - Half-Field Header

    @ViewBuilder
    private func halfFieldHeader(_ field: FormField) -> some View {
        HStack(spacing: 2) {
            Text(field.label)
                .font(.caption)
                .foregroundColor(.secondary)
            if field.isRequired {
                Text("*").font(.caption2).foregroundColor(.red)
            }
        }
    }

    // MARK: - Conditional Logic

    private func evaluateCondition(_ condition: FieldCondition) -> Bool {
        guard let response = responses[condition.triggerFieldID] else { return false }
        switch condition.op {
        case .isYes:        return response.boolValue == true
        case .isNo:         return response.boolValue == false
        case .isPass:       return response.threeStateValue == .pass
        case .isFail:       return response.threeStateValue == .fail
        case .equals:       return (response.textValue ?? "") == condition.value
        case .notEquals:    return (response.textValue ?? "") != condition.value
        case .contains:     return (response.textValue ?? "").contains(condition.value)
        case .greaterThan:
            if let n = response.numberValue { return n > (Decimal(string: condition.value) ?? 0) }
            return false
        case .lessThan:
            if let n = response.numberValue { return n < (Decimal(string: condition.value) ?? 0) }
            return false
        }
    }

    // MARK: - Validation

    private func validate() -> UUID? {
        for field in visibleFields where field.isRequired && !field.type.isLayoutOnly {
            let r = responses[field.id]
            if !hasValue(r, for: field.type) {
                return field.id
            }
        }
        if template.requiresSignature && !isSigned { return nil }
        return nil
    }

    private func hasValue(_ response: FormFieldResponse?, for type: FormFieldType) -> Bool {
        guard let r = response else { return false }
        switch type {
        case .shortText, .text, .longText:
            return !(r.textValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        case .number:
            return r.numberValue != nil
        case .yesNo, .passFail:
            return r.boolValue != nil
        case .yesNoNA, .passFailNA:
            return r.threeStateValue != nil
        case .singleChoice, .dropdown:
            return !(r.selectedOptions ?? []).isEmpty
        case .multipleChoice:
            return !(r.selectedOptions ?? []).isEmpty
        case .date, .time, .dateTime:
            return r.dateValue != nil
        case .photo:
            return !r.photoData.isEmpty
        case .scan:
            return !r.photoData.isEmpty || !(r.textValue ?? "").isEmpty
        case .signature:
            return r.signatureData != nil
        case .rating:
            return r.ratingValue != nil
        case .slider:
            return r.sliderValue != nil
        case .location:
            return r.locationValue != nil
        case .sectionHeader, .instructions:
            return true
        }
    }

    // MARK: - Link Helper

    private func applyLink(to submission: inout FormSubmission) {
        submission.linkType         = linkType
        submission.linkedName       = linkedName.isEmpty ? nil : linkedName
        submission.linkedAddress    = linkedAddress.isEmpty ? nil : linkedAddress
        submission.linkedCoordinate = linkedCoordinate
        switch linkType {
        case .project:
            submission.projectID  = linkedProjectID ?? projectID
            submission.linkedName = store.projects.first { $0.id == submission.projectID }?.name
        case .site, .office, .location:
            submission.projectID = projectID   // keep any contextual project ID passed in
        case .none:
            submission.projectID = projectID
        }
    }

    // MARK: - Save Draft

    private func saveDraft() {
        var submission = FormSubmission(
            templateID: template.id,
            submittedBy: store.currentUser?.fullName ?? "Unknown"
        )
        applyLink(to: &submission)
        submission.responses  = Array(responses.values)
        submission.isDraft    = true
        submission.syncStatus = .local
        store.upsertFormSubmission(submission)
        dismiss()
    }

    // MARK: - Submit

    private func submit(proxy: ScrollViewProxy) {
        // Check required fields
        for field in visibleFields where field.isRequired && !field.type.isLayoutOnly {
            let r = responses[field.id]
            if !hasValue(r, for: field.type) {
                validationMessage = "\"\(field.label)\" is required."
                showValidationError = true
                firstErrorFieldID = field.id
                withAnimation { proxy.scrollTo(field.id, anchor: .center) }
                return
            }
        }
        if template.requiresSignature && !isSigned {
            validationMessage = "Please draw your signature before submitting."
            showValidationError = true
            return
        }

        var submission = FormSubmission(
            templateID: template.id,
            submittedBy: signerName.isEmpty ? (store.currentUser?.fullName ?? "Unknown") : signerName
        )
        applyLink(to: &submission)
        submission.responses         = Array(responses.values)
        submission.isSigned          = isSigned
        submission.signedAt          = isSigned ? Date() : nil
        submission.signedBy          = isSigned ? signerName : nil
        submission.workerSignatures  = workerSignatures.filter { $0.isSigned }
        submission.submittedAt       = Date()
        submission.isDraft           = false
        submission.syncStatus      = .pending
        submission.lastModifiedBy  = store.currentUser?.fullName ?? "Unknown"
        submission.lastModifiedAt  = Date()
        submission.templateVersion = template.version

        // Store signature image in the signature field response if needed
        if let img = signatureImage, let data = img.pngData() {
            let sigFieldID = UUID()
            var sigResponse = FormFieldResponse(fieldID: sigFieldID)
            sigResponse.signatureData = data
            submission.responses.append(sigResponse)
        }

        // ── Legal document locking ────────────────────────────────────
        // Generate SHA-256 fingerprint over the fully assembled submission.
        // This must be done AFTER all response data is finalised.
        submission.auditHash = FormAuditService.generateHash(for: submission)

        store.upsertFormSubmission(submission)

        // Record an immutable audit snapshot for compliance trail
        let eventType = submission.isSigned ? "submitted_and_signed" : "submitted"
        store.createAuditSnapshot(for: submission,
                                  eventType: eventType,
                                  by: submission.submittedBy)

        showSuccess = true
    }
}

// MARK: - Field Response View

struct FieldResponseView: View {
    let field: FormField
    @Binding var response: FormFieldResponse
    var highlightError: Bool = false

    /// Field is locked if auto-variable (read-only label) or permission == .none
    private var isLocked: Bool {
        field.permission == .none || field.autoVariable != nil
    }

    var body: some View {
        Group {
            if isLocked {
                // Show read-only display for locked/auto fields
                HStack(spacing: 6) {
                    if field.autoVariable != nil {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                            .foregroundColor(.yellow)
                    } else {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text(lockedDisplayValue)
                        .font(.subheadline)
                        .foregroundColor(field.autoVariable != nil ? .primary : .secondary)
                    Spacer()
                }
            } else {
            switch field.type {

            // MARK: Text
            case .shortText, .text:
                TextField("Enter response", text: textBinding)
                    .overlay(errorBorder)

            case .longText:
                TextEditor(text: textBinding)
                    .frame(minHeight: 80)
                    .overlay(errorBorder)

            // MARK: Number
            case .number:
                HStack {
                    TextField("0", text: Binding(
                        get: { response.numberValue.map { "\($0)" } ?? "" },
                        set: { response.numberValue = Decimal(string: $0) }
                    ))
                    .keyboardType(.decimalPad)
                    if let unit = field.unit {
                        Text(unit).foregroundColor(.secondary)
                    }
                }
                .overlay(errorBorder)

            // MARK: Date / Time / DateTime
            case .date:
                DatePicker("", selection: dateBinding, displayedComponents: .date)
                    .labelsHidden()

            case .time:
                DatePicker("", selection: dateBinding, displayedComponents: .hourAndMinute)
                    .labelsHidden()

            case .dateTime:
                DatePicker("", selection: dateBinding, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()

            // MARK: Yes / No
            case .yesNo:
                Picker("", selection: Binding<Bool?>(
                    get: { response.boolValue },
                    set: { response.boolValue = $0 }
                )) {
                    Text("—").tag(Bool?.none)
                    Text("Yes").tag(Bool?.some(true))
                    Text("No").tag(Bool?.some(false))
                }
                .pickerStyle(.segmented)

            // MARK: Yes / No / N/A
            case .yesNoNA:
                Picker("", selection: Binding<ThreeStateAnswer?>(
                    get: { response.threeStateValue },
                    set: { response.threeStateValue = $0 }
                )) {
                    Text("—").tag(ThreeStateAnswer?.none)
                    Text("Yes").tag(ThreeStateAnswer?.some(.yes))
                    Text("No").tag(ThreeStateAnswer?.some(.no))
                    Text("N/A").tag(ThreeStateAnswer?.some(.na))
                }
                .pickerStyle(.segmented)

            // MARK: Pass / Fail
            case .passFail:
                Picker("", selection: Binding<Bool?>(
                    get: { response.boolValue },
                    set: { response.boolValue = $0 }
                )) {
                    Text("—").tag(Bool?.none)
                    Text("Pass").tag(Bool?.some(true))
                    Text("Fail").tag(Bool?.some(false))
                }
                .pickerStyle(.segmented)

            // MARK: Pass / Fail / N/A
            case .passFailNA:
                Picker("", selection: Binding<ThreeStateAnswer?>(
                    get: { response.threeStateValue },
                    set: { response.threeStateValue = $0 }
                )) {
                    Text("—").tag(ThreeStateAnswer?.none)
                    Text("Pass").tag(ThreeStateAnswer?.some(.pass))
                    Text("Fail").tag(ThreeStateAnswer?.some(.fail))
                    Text("N/A").tag(ThreeStateAnswer?.some(.na))
                }
                .pickerStyle(.segmented)

            // MARK: Single Choice (radio)
            case .singleChoice:
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(field.options ?? [], id: \.self) { option in
                        let isSelected = (response.selectedOptions ?? []).first == option
                        Button {
                            response.selectedOptions = [option]
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                    .foregroundColor(isSelected ? .blue : .secondary)
                                Text(option).foregroundColor(.primary)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

            // MARK: Multiple Choice (checkboxes)
            case .multipleChoice:
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(field.options ?? [], id: \.self) { option in
                        let isSelected = (response.selectedOptions ?? []).contains(option)
                        Button {
                            var current = response.selectedOptions ?? []
                            if isSelected { current.removeAll { $0 == option } }
                            else { current.append(option) }
                            response.selectedOptions = current
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                    .foregroundColor(isSelected ? .blue : .secondary)
                                Text(option).foregroundColor(.primary)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

            // MARK: Dropdown
            case .dropdown:
                Picker("Select…", selection: Binding(
                    get: { (response.selectedOptions ?? []).first ?? "" },
                    set: { response.selectedOptions = [$0] }
                )) {
                    Text("Select…").tag("")
                    ForEach(field.options ?? [], id: \.self) { opt in
                        Text(opt).tag(opt)
                    }
                }

            // MARK: Rating
            case .rating:
                HStack(spacing: 4) {
                    ForEach(1...field.ratingMax, id: \.self) { star in
                        let selected = (response.ratingValue ?? 0) >= star
                        Button {
                            response.ratingValue = star
                        } label: {
                            Image(systemName: selected ? "star.fill" : "star")
                                .foregroundColor(selected ? .yellow : .secondary)
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    if let rv = response.ratingValue {
                        Text("\(rv) / \(field.ratingMax)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

            // MARK: Slider
            case .slider:
                VStack(spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { response.sliderValue ?? field.sliderMin },
                            set: { response.sliderValue = $0 }
                        ),
                        in: field.sliderMin...max(field.sliderMax, field.sliderMin + 1),
                        step: field.sliderStep
                    )
                    HStack {
                        Text(field.sliderMinLabel ?? "\(Int(field.sliderMin))")
                            .font(.caption2).foregroundColor(.secondary)
                        Spacer()
                        if let v = response.sliderValue {
                            Text(String(format: v.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", v))
                                .font(.caption).bold()
                        }
                        Spacer()
                        Text(field.sliderMaxLabel ?? "\(Int(field.sliderMax))")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }

            // MARK: Photo
            case .photo:
                PhotoFieldView(response: $response)

            // MARK: Document Scan
            case .scan:
                DocumentScanFieldView(response: $response)

            // MARK: Signature
            case .signature:
                Text("Signature field — use the form-level signature at the bottom.")
                    .font(.caption)
                    .foregroundColor(.secondary)

            // MARK: Location
            case .location:
                LocationFieldView(response: $response)

            // Layout-only — never shown here (filtered upstream)
            case .sectionHeader, .instructions:
                EmptyView()
            }
            } // end else (not locked)
        }
    }

    // MARK: - Locked Display Value

    private var lockedDisplayValue: String {
        if let v = response.textValue, !v.isEmpty { return v }
        if let d = response.dateValue {
            switch field.type {
            case .date:     return d.formatted(date: .long, time: .omitted)
            case .time:     return d.formatted(date: .omitted, time: .shortened)
            default:        return d.formatted()
            }
        }
        if let v = field.autoVariable { return "Auto: \(v.displayName)" }
        return field.permission == .none ? "(read only)" : "—"
    }

    // MARK: - Helpers

    private var textBinding: Binding<String> {
        Binding(
            get: { response.textValue ?? "" },
            set: { response.textValue = $0 }
        )
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { response.dateValue ?? Date() },
            set: { response.dateValue = $0 }
        )
    }

    private var errorBorder: some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(highlightError ? Color.red : Color.clear, lineWidth: 1.5)
    }
}

// MARK: - Photo Field View

struct PhotoFieldView: View {
    @Binding var response: FormFieldResponse
    @State private var selectedItems: [PhotosPickerItem] = []
    /// FIX (debug audit): live camera for form-attached photos.
    @State private var showCamera = false
    @State private var capturedPhoto: UIImage? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Existing photos
            if !response.photoData.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(response.photoData.enumerated()), id: \.offset) { idx, data in
                            if let img = UIImage(data: data) {
                                ZStack(alignment: .topTrailing) {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 80, height: 80)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))

                                    Button {
                                        response.photoData.remove(at: idx)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.white)
                                            .shadow(radius: 2)
                                    }
                                    .offset(x: 6, y: -6)
                                }
                            }
                        }
                    }
                }
            }

            // FIX (debug audit): camera + library side-by-side.
            HStack(spacing: 10) {
                if CameraPicker.isAvailable {
                    Button {
                        showCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera.fill")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
                PhotosPicker(
                    selection: $selectedItems,
                    maxSelectionCount: 5,
                    matching: .images
                ) {
                    Label(response.photoData.isEmpty ? "From Library" : "Add Another",
                          systemImage: "photo.on.rectangle")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.blue.opacity(0.08))
                        .foregroundColor(.blue)
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: selectedItems) { _, items in
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        // Compress to ~500KB
                        let compressed = compressPhoto(data)
                        response.photoData.append(compressed)
                    }
                }
                selectedItems = []
            }
        }
        // FIX (debug audit): live camera sheet.
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(image: $capturedPhoto)
                .ignoresSafeArea()
        }
        .onChange(of: capturedPhoto) { _, img in
            guard let img = img,
                  let raw = img.jpegData(compressionQuality: 0.9) else { return }
            response.photoData.append(compressPhoto(raw))
            capturedPhoto = nil
        }
    }

}

// MARK: - Document Scan Field View

import VisionKit
import Vision

struct DocumentScanFieldView: View {
    @Binding var response: FormFieldResponse
    @State private var showScanner = false
    @State private var isRecognizing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let firstPhotoData = response.photoData.first,
               let img = UIImage(data: firstPhotoData) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let text = response.textValue, !text.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Extracted Text", systemImage: "text.viewfinder")
                        .font(.caption).foregroundColor(.secondary)
                    Text(text)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .padding(8)
                        .background(Color(.tertiarySystemBackground))
                        .cornerRadius(8)
                }
            }

            if isRecognizing {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Recognizing text…").font(.subheadline).foregroundColor(.secondary)
                }
            } else {
                Button {
                    showScanner = true
                } label: {
                    Label(response.photoData.isEmpty ? "Scan Document" : "Re-scan",
                          systemImage: "doc.viewfinder")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.blue.opacity(0.08))
                        .foregroundColor(.blue)
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showScanner) {
            if VNDocumentCameraViewController.isSupported {
                DocumentScannerRepresentable { images in
                    guard let first = images.first else { return }
                    if let data = first.jpegData(compressionQuality: 0.8) {
                        response.photoData = [data]
                    }
                    isRecognizing = true
                    recognizeText(from: images)
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "camera.slash").font(.largeTitle).foregroundColor(.secondary)
                    Text("Document scanning requires a physical device.")
                        .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                    Button("Close") { showScanner = false }.foregroundColor(.blue)
                }
                .padding()
            }
        }
    }

    private func recognizeText(from images: [UIImage]) {
        Task.detached(priority: .userInitiated) {
            var parts: [String] = []
            for image in images {
                guard let cgImage = image.cgImage else { continue }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])
                let lines = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                parts.append(contentsOf: lines)
            }
            let result = parts.joined(separator: "\n")
            await MainActor.run {
                response.textValue = result
                isRecognizing = false
            }
        }
    }
}

struct DocumentScannerRepresentable: UIViewControllerRepresentable {
    let onScan: ([UIImage]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScan: ([UIImage]) -> Void
        init(onScan: @escaping ([UIImage]) -> Void) { self.onScan = onScan }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            var images: [UIImage] = []
            for i in 0..<scan.pageCount {
                images.append(scan.imageOfPage(at: i))
            }
            controller.dismiss(animated: true) { self.onScan(images) }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            controller.dismiss(animated: true)
        }
    }
}

// MARK: - Location Field View

struct LocationFieldView: View {
    @Binding var response: FormFieldResponse
    @State private var isFetching = false
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let loc = response.locationValue {
                VStack(alignment: .leading, spacing: 4) {
                    if let address = loc.address {
                        Text(address).font(.subheadline)
                    }
                    Text(String(format: "%.5f, %.5f", loc.latitude, loc.longitude))
                        .font(.caption).foregroundColor(.secondary)
                }
                Button("Update Location") { fetchLocation() }
                    .font(.caption).foregroundColor(.blue)
            } else {
                Button {
                    fetchLocation()
                } label: {
                    HStack {
                        if isFetching {
                            ProgressView().scaleEffect(0.8)
                            Text("Getting location…")
                        } else {
                            Image(systemName: "location.fill")
                            Text("Capture GPS Location")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.blue.opacity(0.08))
                    .foregroundColor(.blue)
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(isFetching)
            }
            if let err = errorMessage {
                Text(err).font(.caption).foregroundColor(.red)
            }
        }
    }

    private func fetchLocation() {
        isFetching = true
        errorMessage = nil
        LocationCapture.shared.requestOnce { result in
            isFetching = false
            switch result {
            case .success(let loc):
                response.locationValue = loc
            case .failure(let err):
                errorMessage = err.localizedDescription
            }
        }
    }
}

// MARK: - Location Capture Helper

final class LocationCapture: NSObject, CLLocationManagerDelegate {
    static let shared = LocationCapture()
    private let manager = CLLocationManager()
    private var completion: ((Result<LocationResponse, Error>) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestOnce(_ completion: @escaping (Result<LocationResponse, Error>) -> Void) {
        self.completion = completion
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.first else { return }
        let locResponse = LocationResponse(
            latitude: loc.coordinate.latitude,
            longitude: loc.coordinate.longitude,
            address: nil
        )
        completion?(.success(locResponse))
        completion = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        completion?(.failure(error))
        completion = nil
    }
}

// MARK: - Signature Canvas Sheet

struct SignatureCanvasSheet: View {
    let onSave: (UIImage?) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var lines: [SignatureLine] = []
    @State private var currentLine: SignatureLine? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Sign in the box below")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.top, 12)

                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.4), lineWidth: 1.5)
                        .background(Color.white.clipShape(RoundedRectangle(cornerRadius: 12)))
                        .padding()

                    // Baseline guide
                    GeometryReader { geo in
                        Path { p in
                            let y = geo.size.height * 0.72
                            p.move(to: CGPoint(x: 32, y: y))
                            p.addLine(to: CGPoint(x: geo.size.width - 32, y: y))
                        }
                        .stroke(Color.blue.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    }
                    .padding()

                    Canvas { context, size in
                        for line in lines {
                            drawLine(context: context, line: line)
                        }
                        if let current = currentLine {
                            drawLine(context: context, line: current)
                        }
                    }
                    .padding()
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if currentLine == nil {
                                    currentLine = SignatureLine(points: [value.location])
                                } else {
                                    currentLine?.points.append(value.location)
                                }
                            }
                            .onEnded { _ in
                                if let line = currentLine {
                                    lines.append(line)
                                }
                                currentLine = nil
                            }
                    )
                }
                .frame(maxHeight: 260)

                HStack {
                    Button("Clear") { lines = []; currentLine = nil }
                        .foregroundColor(.red)
                    Spacer()
                    Text(lines.isEmpty ? "Draw your signature above" : "")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)

                Spacer()
            }
            .navigationTitle("Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        onSave(nil)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        onSave(renderSignature())
                        dismiss()
                    }
                    .bold()
                    .disabled(lines.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func drawLine(context: GraphicsContext, line: SignatureLine) {
        guard line.points.count > 1 else { return }
        var path = Path()
        path.move(to: line.points[0])
        for pt in line.points.dropFirst() {
            path.addLine(to: pt)
        }
        context.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }

    private func renderSignature() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 160))
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 160))
            ctx.cgContext.setStrokeColor(UIColor.black.cgColor)
            ctx.cgContext.setLineWidth(2.5)
            ctx.cgContext.setLineCap(.round)
            ctx.cgContext.setLineJoin(.round)
            for line in lines {
                guard line.points.count > 1 else { continue }
                ctx.cgContext.move(to: line.points[0])
                for pt in line.points.dropFirst() {
                    ctx.cgContext.addLine(to: pt)
                }
                ctx.cgContext.strokePath()
            }
        }
    }
}

struct SignatureLine {
    var points: [CGPoint]
}

// MARK: - Form Submission List View

struct FormSubmissionListView: View {
    var projectID: UUID? = nil
    @EnvironmentObject var store: AppStore
    @State private var showSubmit = false
    @State private var selectedSubmission: FormSubmission? = nil

    private var submissions: [FormSubmission] {
        store.formSubmissions
            .filter { projectID == nil || $0.projectID == projectID }
            .sorted { ($0.submittedAt ?? $0.createdAt) > ($1.submittedAt ?? $1.createdAt) }
    }

    var body: some View {
        Group {
            if submissions.isEmpty {
                EmptyCard(message: "No forms submitted yet.")
            } else {
                VStack(spacing: 10) {
                    ForEach(submissions) { submission in
                        FormSubmissionRow(submission: submission)
                            .onTapGesture { selectedSubmission = submission }
                            .padding(.horizontal)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showSubmit = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showSubmit) {
            FormPickerSheet(projectID: projectID)
        }
        .sheet(item: $selectedSubmission) { submission in
            FormSubmissionDetailView(submission: submission)
        }
    }
}

// MARK: - Form Submission Row

struct FormSubmissionRow: View {
    let submission: FormSubmission
    @EnvironmentObject var store: AppStore

    private var templateName: String {
        store.formTemplates.first { $0.id == submission.templateID }?.name ?? "Unknown Form"
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(rowColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: rowIcon)
                    .foregroundColor(rowColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(templateName).font(.subheadline).bold()
                Text("By \(submission.submittedBy)")
                    .font(.caption).foregroundColor(.secondary)
                if let date = submission.submittedAt ?? (submission.isDraft ? submission.createdAt : nil) {
                    Text(date.shortDate)
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if submission.isDraft {
                    badgeLabel("Draft", color: .orange)
                } else if submission.isSigned {
                    badgeLabel("Signed", color: .green)
                } else {
                    badgeLabel("Submitted", color: .blue)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var rowIcon: String {
        submission.isDraft ? "doc.badge.clock" : (submission.isSigned ? "checkmark.seal.fill" : "doc.text")
    }
    private var rowColor: Color {
        submission.isDraft ? .orange : (submission.isSigned ? .green : .blue)
    }
    private func badgeLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2).bold()
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.12))
            .foregroundColor(color)
            .cornerRadius(4)
    }
}

// MARK: - Form Picker Sheet

struct FormPickerSheet: View {
    var projectID: UUID? = nil
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var selectedTemplate: FormTemplate? = nil
    @State private var showSubmission = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.formTemplates.filter { $0.isActive }) { template in
                    Button {
                        selectedTemplate = template
                        showSubmission = true
                    } label: {
                        FormTemplateRow(template: template)
                    }
                    .foregroundColor(.primary)
                }
            }
            .navigationTitle("Select Form")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showSubmission) {
                if let template = selectedTemplate {
                    FormSubmissionView(template: template, projectID: projectID)
                        .environmentObject(store)
                }
            }
        }
    }
}
