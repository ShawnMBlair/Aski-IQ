// ScheduleEntryCreateEditView.swift
// FieldOS – Create / Edit Schedule Entry

import SwiftUI

struct ScheduleEntryCreateEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    var existing: ScheduleEntry? = nil
    var preselectedDate: Date = Date()
    /// Phase 1 — when launched from CrewCalendarView, pre-pick the
    /// crew so the form lands tied to the right one. Optional —
    /// nil means "don't pre-select".
    var preselectedCrewID: UUID? = nil
    /// Phase A — Scheduling Command Centre. Carries source record
    /// context (quote / material sale / change order / project) into
    /// this editor so we can pre-fill project, client, site, work
    /// type, suggested crew/date, and required certifications without
    /// asking the user to re-enter known data. nil for the legacy
    /// "create from blank" flows.
    var sourceContext: ScheduleSourceContext? = nil

    @State private var projectID: UUID? = nil
    @State private var crewID: UUID? = nil
    /// RA-3: 3-mode assignment editor.
    /// - fixedCrew: crewID required; assignedWorkerIDs empty (model
    ///   defaults to crew.memberIDs) UNLESS the user opts into a
    ///   per-shift roster override (RA-3 stretch — kept simple here:
    ///   no override UI yet, that's RA-3.5).
    /// - customCrew: assignedWorkerIDs is the roster, crewID nil
    ///   (could optionally be set as a "based on Crew X" hint, but
    ///   we don't store that). Foreman optional, must be in roster.
    /// - individualWorker: assignedWorkerIDs is exactly one worker,
    ///   crewID nil, no foreman.
    @State private var assignmentMode: ScheduleAssignmentMode = .fixedCrew
    @State private var assignedWorkerIDs: Set<UUID> = []
    @State private var customForemanID: UUID? = nil
    @State private var date: Date = Date()
    @State private var hasShiftStart = false
    @State private var shiftStart: Date = Date()
    @State private var hasShiftEnd = false
    @State private var shiftEnd: Date = Date().addingTimeInterval(3600 * 8)
    @State private var status: ScheduleEntryStatus = .scheduled
    @State private var taskDescription = ""
    @State private var costCode = ""
    @State private var location = ""
    @State private var notes = ""
    /// Phase 1 — required-certifications editor. Free-text array;
    /// matches Employee.certifications shape.
    @State private var requiredCertifications: [String] = []
    @State private var newCertText: String = ""

    @State private var showValidationError = false
    @State private var validationMessage = ""
    @State private var showCopyPicker = false

    // Crew double-booking confirmation
    @State private var pendingConflict: ScheduleConflict? = nil
    @State private var pendingEntry:    ScheduleEntry?    = nil

    private var isEditing: Bool { existing != nil }

    private var activeProjects: [Project] {
        store.projects.filter { $0.status == .active }.sorted { $0.name < $1.name }
    }

    private var activeCrews: [Crew] {
        store.crews.filter { $0.isActive }.sorted { $0.name < $1.name }
    }

    /// RA-3: active employees for custom-crew + individual-worker
    /// modes. Sorted last-name-first for picker readability.
    private var activeEmployees: [Employee] {
        store.employees
            .filter { $0.isActive && !$0.isDeleted }
            .sorted {
                if $0.lastName != $1.lastName { return $0.lastName < $1.lastName }
                return $0.firstName < $1.firstName
            }
    }

    /// Workers eligible to be foreman of a custom crew — must be in
    /// the selected roster. Empty when the user hasn't picked any.
    private var customForemanCandidates: [Employee] {
        activeEmployees.filter { assignedWorkerIDs.contains($0.id) }
    }

    // Last job setup for "Copy" feature
    private var lastEntry: ScheduleEntry? {
        store.scheduleEntries
            .filter { $0.id != existing?.id }
            .sorted { $0.date > $1.date }
            .first
    }

    var body: some View {
        NavigationStack {
            Form {

                // MARK: - Copy Last Job
                if !isEditing, lastEntry != nil {
                    Section {
                        Button {
                            copyLastJobSetup()
                        } label: {
                            Label("Copy Last Job Setup", systemImage: "doc.on.doc")
                                .foregroundColor(.blue)
                        }
                    } footer: {
                        if let last = lastEntry,
                           let proj = store.project(id: last.projectID) {
                            Text("Last: \(proj.name) · \(last.date.shortDate)")
                        }
                    }
                }

                // MARK: - Project (always shown)
                Section("Project *") {
                    Picker("Project", selection: $projectID) {
                        Text("Select Project").tag(UUID?.none)
                        ForEach(activeProjects) { p in
                            Text(p.name).tag(Optional(p.id))
                        }
                    }
                    .pickerStyle(.menu)
                }

                // MARK: - RA-3: Assignment Mode
                // Three operational shapes. The picker ALWAYS shows so
                // the user can pivot at any point during the edit
                // without having to "convert" the shift. Validation
                // (AppStore.assignmentShapeError) blocks save when
                // the mode/data don't match.
                Section {
                    Picker("Mode", selection: $assignmentMode) {
                        ForEach(ScheduleAssignmentMode.allCases, id: \.self) { mode in
                            Text(mode.displayLabel).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Assignment")
                } footer: {
                    Text(assignmentMode.editorHint)
                        .font(.caption)
                }

                // MARK: - Mode-conditional body
                switch assignmentMode {
                case .fixedCrew:
                    fixedCrewSection
                case .customCrew:
                    customCrewSection
                case .individualWorker:
                    individualWorkerSection
                }

                // MARK: - Date + Time
                Section("Date & Time") {
                    DatePicker("Date", selection: $date, displayedComponents: .date)

                    Toggle("Set Shift Start", isOn: $hasShiftStart)
                    if hasShiftStart {
                        DatePicker("Start Time", selection: $shiftStart, displayedComponents: .hourAndMinute)
                    }

                    Toggle("Set Shift End", isOn: $hasShiftEnd)
                    if hasShiftEnd {
                        DatePicker("End Time", selection: $shiftEnd, displayedComponents: .hourAndMinute)
                    }
                }

                // MARK: - Status (edit only)
                if isEditing {
                    Section("Status") {
                        Picker("Status", selection: $status) {
                            ForEach(ScheduleEntryStatus.allCases, id: \.self) { s in
                                Text(s.rawValue.capitalized).tag(s)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                // MARK: - Work Details
                Section("Work Details") {
                    TextField("Task Description", text: $taskDescription)
                    TextField("Cost Code (e.g. INS-001)", text: $costCode)
                    TextField("Location / Area on Site", text: $location)
                }

                // MARK: - Required Certifications (Phase 1)
                // Lists individual cert names. Conflict service flags
                // the shift if no crew member carries every required
                // cert. Empty list = no requirement.
                Section {
                    if requiredCertifications.isEmpty {
                        Text("No certifications required.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(requiredCertifications, id: \.self) { cert in
                            HStack {
                                Image(systemName: "checkmark.shield.fill")
                                    .foregroundColor(.indigo)
                                Text(cert)
                                Spacer()
                                Button(role: .destructive) {
                                    requiredCertifications.removeAll { $0 == cert }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    HStack {
                        TextField("e.g. WHMIS, Fall Protection", text: $newCertText)
                            .textInputAutocapitalization(.words)
                        Button {
                            addCertFromInput()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                        .disabled(newCertText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Required Certifications")
                } footer: {
                    Text("Conflict alerts fire when no member of the assigned crew carries every required cert. Match free-text against Employee.certifications (case-insensitive).")
                        .font(.caption)
                }

                // MARK: - Notes
                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 60)
                }

                // MARK: - Delete
                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            // Removal handled via AppStore in future sprint
                            dismiss()
                        } label: {
                            Label("Delete Entry", systemImage: "trash")
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(isEditing ? "Edit Shift" : "New Shift")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }.bold()
                }
            }
            .alert("Missing Info", isPresented: $showValidationError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationMessage)
            }
            .alert(
                "Crew Double-Booked",
                isPresented: Binding(
                    get: { pendingConflict != nil },
                    set: { if !$0 { pendingConflict = nil; pendingEntry = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) {
                    pendingConflict = nil
                    pendingEntry = nil
                }
                Button("Schedule Anyway", role: .destructive) {
                    if let entry = pendingEntry {
                        store.upsertScheduleEntry(entry, force: true)
                        pendingConflict = nil
                        pendingEntry = nil
                        dismiss()
                    }
                }
            } message: {
                Text(pendingConflict?.description ?? "Crew is already on another project that day.")
            }
            .onAppear { populate() }
        }
    }

    // MARK: - Copy Last Job Setup

    private func copyLastJobSetup() {
        guard let last = lastEntry else { return }
        projectID = last.projectID
        crewID = last.crewID
        taskDescription = last.taskDescription ?? ""
        costCode = last.costCode ?? ""
        location = last.location ?? ""
    }

    // MARK: - Populate

    private func populate() {
        date = preselectedDate
        if let preselectedCrewID, crewID == nil {
            crewID = preselectedCrewID
        }

        // Phase A: source-context prefill. Only applies when this is
        // a NEW entry (existing == nil) so we don't clobber an edit
        // in flight. Each field falls back to whatever was already
        // typed — gentle fill, never destructive.
        if existing == nil, let ctx = sourceContext {
            if projectID == nil, let pid = ctx.projectID { projectID = pid }
            if crewID == nil, let cid = ctx.suggestedCrewID { crewID = cid }
            if let d = ctx.suggestedDate { date = d }
            if let s = ctx.suggestedStartTime {
                shiftStart = s
                hasShiftStart = true
            }
            if let e = ctx.suggestedEndTime {
                shiftEnd = e
                hasShiftEnd = true
            }
            if costCode.isEmpty, let cc = ctx.costCode { costCode = cc }
            if location.isEmpty, let addr = ctx.siteAddress { location = addr }
            if taskDescription.isEmpty, let work = ctx.workType {
                taskDescription = work
            }
            if requiredCertifications.isEmpty {
                requiredCertifications = ctx.requiredCertifications
            }
        }

        guard let e = existing else { return }
        projectID = e.projectID
        crewID = e.crewID
        date = e.date
        status = e.status
        taskDescription = e.taskDescription ?? ""
        costCode = e.costCode ?? ""
        location = e.location ?? ""
        notes = e.notes ?? ""
        requiredCertifications = e.requiredCertifications
        // RA-3: hydrate the assignment-mode editor from the existing
        // entry's persisted state.
        assignmentMode    = e.assignmentMode
        assignedWorkerIDs = Set(e.assignedWorkerIDs)
        customForemanID   = e.foremanID
        if let start = e.shiftStart {
            shiftStart = start
            hasShiftStart = true
        }
        if let end = e.shiftEnd {
            shiftEnd = end
            hasShiftEnd = true
        }
    }

    // MARK: - Save

    private func save() {
        guard let pid = projectID else {
            validationMessage = "Please select a project."
            showValidationError = true
            return
        }

        // RA-3: assignment-mode shape validation BEFORE we hit AppStore.
        // AppStore also validates (the safety net), but doing it here
        // means the user sees a clear alert and the editor stays open
        // to fix the issue, instead of dismissing on a toast.
        if let shapeMsg = localAssignmentShapeError() {
            validationMessage = shapeMsg
            showValidationError = true
            return
        }

        var entry = existing ?? ScheduleEntry(projectID: pid, date: date)
        entry.projectID = pid
        entry.date = date
        entry.shiftStart = hasShiftStart ? shiftStart : nil
        entry.shiftEnd = hasShiftEnd ? shiftEnd : nil
        entry.status = status
        entry.taskDescription = taskDescription.isEmpty ? nil : taskDescription
        entry.costCode = costCode.isEmpty ? nil : costCode
        entry.location = location.isEmpty ? nil : location
        entry.notes = notes.isEmpty ? nil : notes
        // Phase 1 — persist the required-certifications list.
        // Trim + dedupe (case-insensitive) so the user can't end up
        // with " whmis " and "WHMIS" both stored.
        entry.requiredCertifications = normalizedCertList(requiredCertifications)

        // RA-3: assignment-mode-aware stamping. Each mode produces a
        // distinct shape; the AppStore validation layer
        // (assignmentShapeError) is the safety net if the user has
        // somehow mismatched the picker and the data.
        entry.assignmentMode = assignmentMode
        switch assignmentMode {
        case .fixedCrew:
            entry.crewID = crewID
            // Empty workers = "use crew roster". Per-shift override
            // lands in a follow-up.
            entry.assignedWorkerIDs = []
            entry.foremanID = nil
        case .customCrew:
            // crewID intentionally cleared — custom crews aren't
            // standing crews. (A future "based on Crew X" hint could
            // store crewID without claiming the crew is the unit.)
            entry.crewID = nil
            entry.assignedWorkerIDs = Array(assignedWorkerIDs)
            entry.foremanID = customForemanID
        case .individualWorker:
            entry.crewID = nil
            entry.assignedWorkerIDs = Array(assignedWorkerIDs)
            entry.foremanID = nil
        }

        entry.updatedAt = Date()
        entry.lastModifiedAt = Date()
        entry.syncStatus = .pending

        if let conflict = store.upsertScheduleEntry(entry) {
            // Crew double-book detected — surface a confirmation alert.
            pendingEntry = entry
            pendingConflict = conflict
            return
        }
        dismiss()
    }

    // MARK: - Cert helpers (Phase 1)

    /// Adds the current text-field input to the required-certs list,
    /// trimming whitespace and skipping case-insensitive duplicates.
    /// Clears the field afterwards so the user can keep typing more.
    private func addCertFromInput() {
        let trimmed = newCertText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let lower = trimmed.lowercased()
        guard !requiredCertifications.contains(where: { $0.lowercased() == lower }) else {
            newCertText = ""
            return
        }
        requiredCertifications.append(trimmed)
        newCertText = ""
    }

    // MARK: - RA-3: Mode-specific sections

    /// Fixed-crew mode: pick a standing crew. Workers + foreman are
    /// inherited from `Crew.memberIDs` / `Crew.foremanID` at conflict-
    /// detection time. RA-3 does NOT yet expose a per-shift roster
    /// override (the model supports it via assignedWorkerIDs but UI
    /// for that lands in a follow-up).
    @ViewBuilder
    private var fixedCrewSection: some View {
        Section {
            Picker("Crew", selection: $crewID) {
                Text("No crew yet").tag(UUID?.none)
                ForEach(activeCrews) { c in
                    Text(c.name).tag(Optional(c.id))
                }
            }
            .pickerStyle(.menu)
            if let cid = crewID, let crew = activeCrews.first(where: { $0.id == cid }) {
                let memberCount = crew.memberIDs.count
                let foremanName = crew.foremanID
                    .flatMap { fid in store.employees.first(where: { $0.id == fid }) }?
                    .fullName ?? "—"
                Label("\(memberCount) member\(memberCount == 1 ? "" : "s") · Foreman: \(foremanName)",
                      systemImage: "person.3.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Crew")
        } footer: {
            Text("Workers and foreman come from the crew's standing roster. To assign a different mix of workers for this shift only, switch to Custom Crew.")
                .font(.caption)
        }
    }

    /// Custom-crew mode: assemble workers for THIS shift only.
    /// "Use Crew Members" quick-fill seeds the multi-select from a
    /// standing crew's roster (the user can then edit). Foreman is
    /// optional but if set must be one of the assigned workers.
    @ViewBuilder
    private var customCrewSection: some View {
        Section {
            // Quick-fill: seed from a standing crew, then edit.
            // Reduces the typical "I want most of Crew A but not Bob"
            // case from 6 taps to 2.
            if !activeCrews.isEmpty {
                Menu {
                    ForEach(activeCrews) { crew in
                        Button(crew.name) {
                            seedRoster(from: crew)
                        }
                    }
                } label: {
                    Label("Seed from existing crew", systemImage: "person.3.sequence")
                }
            }
            ForEach(activeEmployees) { emp in
                Button {
                    toggleWorker(emp.id)
                } label: {
                    HStack {
                        Image(systemName: assignedWorkerIDs.contains(emp.id)
                              ? "checkmark.square.fill"
                              : "square")
                            .foregroundColor(assignedWorkerIDs.contains(emp.id) ? .blue : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(emp.fullName)
                                .foregroundColor(.primary)
                            if let trade = emp.trade, !trade.isEmpty {
                                Text(trade)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Workers (\(assignedWorkerIDs.count) selected)")
        } footer: {
            if assignedWorkerIDs.isEmpty {
                Text("Select at least one worker.")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else {
                Text("Custom crews are temporary — they apply to this shift only and aren't saved as a permanent crew.")
                    .font(.caption)
            }
        }

        Section {
            Picker("Foreman (optional)", selection: $customForemanID) {
                Text("No foreman").tag(UUID?.none)
                ForEach(customForemanCandidates) { emp in
                    Text(emp.fullName).tag(Optional(emp.id))
                }
            }
            .pickerStyle(.menu)
            .disabled(customForemanCandidates.isEmpty)
            // If the previously-selected foreman is no longer in the
            // roster (user removed them), null it out automatically
            // so save validation doesn't fail unexpectedly.
            .onChange(of: assignedWorkerIDs) { _, newRoster in
                if let f = customForemanID, !newRoster.contains(f) {
                    customForemanID = nil
                }
            }
        } header: {
            Text("Foreman")
        } footer: {
            Text("Foreman must be one of the assigned workers above.")
                .font(.caption)
        }
    }

    /// Individual-worker mode: one person is enough. Single-select
    /// picker. No foreman concept — there's no role to fill.
    @ViewBuilder
    private var individualWorkerSection: some View {
        Section {
            Picker("Worker", selection: individualWorkerBinding) {
                Text("Select Worker").tag(UUID?.none)
                ForEach(activeEmployees) { emp in
                    Text(emp.fullName).tag(Optional(emp.id))
                }
            }
            .pickerStyle(.menu)
            if let workerID = assignedWorkerIDs.first,
               let emp = store.employees.first(where: { $0.id == workerID }) {
                if let trade = emp.trade, !trade.isEmpty {
                    Label(trade, systemImage: "wrench.and.screwdriver")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if !emp.certifications.isEmpty {
                    Label(emp.certifications.joined(separator: " · "),
                          systemImage: "checkmark.shield")
                        .font(.caption)
                        .foregroundColor(.indigo)
                }
            }
        } header: {
            Text("Worker")
        } footer: {
            Text("Use this mode when one person is enough — small deliveries, quick service calls, single-person inspections.")
                .font(.caption)
        }
    }

    /// Single-select binding for individualWorker mode. Read returns
    /// the first (and only) worker; write replaces the whole set.
    private var individualWorkerBinding: Binding<UUID?> {
        Binding(
            get: { assignedWorkerIDs.first },
            set: { newValue in
                if let v = newValue {
                    assignedWorkerIDs = [v]
                } else {
                    assignedWorkerIDs = []
                }
            }
        )
    }

    /// RA-3: client-side mirror of AppStore.assignmentShapeError so the
    /// editor can surface a clean alert instead of letting the upsert
    /// toast fire after dismiss. Returns nil when the form is valid.
    /// Kept in sync with the server-authoritative version in AppStore.
    private func localAssignmentShapeError() -> String? {
        switch assignmentMode {
        case .fixedCrew:
            if crewID == nil {
                return "Pick a crew, or switch to Custom Crew or Individual Worker."
            }
            return nil
        case .customCrew:
            if assignedWorkerIDs.isEmpty {
                return "Custom Crew needs at least one worker. Tap workers to add them."
            }
            if let f = customForemanID, !assignedWorkerIDs.contains(f) {
                return "Foreman must be one of the assigned workers."
            }
            return nil
        case .individualWorker:
            if assignedWorkerIDs.count != 1 {
                return "Individual Worker needs exactly one worker selected."
            }
            return nil
        }
    }

    /// Toggle membership in the custom-crew roster. Used by the
    /// multi-select rows.
    private func toggleWorker(_ id: UUID) {
        if assignedWorkerIDs.contains(id) {
            assignedWorkerIDs.remove(id)
        } else {
            assignedWorkerIDs.insert(id)
        }
    }

    /// Seed the custom-crew roster from a standing crew's members +
    /// foreman. Replaces the current selection (the user can then
    /// remove individuals). Pre-selects the crew's foreman as the
    /// custom foreman if it's a member.
    private func seedRoster(from crew: Crew) {
        var roster = Set(crew.memberIDs)
        if let f = crew.foremanID {
            roster.insert(f)
            customForemanID = f
        }
        assignedWorkerIDs = roster
    }

    /// Normalizes a list before persisting: trims each entry, drops
    /// empties, and dedupes case-insensitively (keeping the first
    /// casing variant the user typed).
    private func normalizedCertList(_ list: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in list {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed.lowercased()).inserted {
                out.append(trimmed)
            }
        }
        return out
    }
}

extension ScheduleEntryStatus: CaseIterable {
    public static var allCases: [ScheduleEntryStatus] {
        [.scheduled, .inProgress, .completed, .cancelled, .rescheduled]
    }
}

// MARK: - RA-3: Mode editor hints
//
// One-line description for each mode, shown as the picker's footer
// so the user always sees what the active mode means without leaving
// the form.
extension ScheduleAssignmentMode {
    var editorHint: String {
        switch self {
        case .fixedCrew:
            return "Standard crew work. Pick a crew below; workers and foreman come from the crew."
        case .customCrew:
            return "Assemble a temporary team for this shift only. Useful when you need a specific mix of workers."
        case .individualWorker:
            return "Assign one person. Best for small deliveries, single-person service calls."
        }
    }
}
