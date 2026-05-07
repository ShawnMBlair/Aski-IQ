// ProjectCreateEditView.swift
// Aski IQ – Create / Edit Project
// Updated: client + site pickers replace free-text client name field

import SwiftUI

struct ProjectCreateEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    var existing: Project? = nil

    // Relationship pickers
    @State private var selectedClientID:    UUID? = nil
    @State private var selectedSiteID:      UUID? = nil
    @State private var showClientPicker     = false
    @State private var showSitePicker       = false

    // Form state
    @State private var name:                    String = ""
    @State private var clientName:              String = ""   // kept for backward compat display
    @State private var status:                  ProjectStatus = .active
    @State private var startDate:               Date = Date()
    @State private var hasStartDate:            Bool = true
    @State private var endDate:                 Date = Date().addingTimeInterval(60 * 60 * 24 * 90)
    @State private var hasEndDate:              Bool = false
    @State private var contractValueString:     String = ""
    @State private var estimatedBudgetString:   String = ""
    @State private var notes:                   String = ""

    @State private var showValidationError = false
    @State private var validationMessage   = ""

    @State private var showDeletionBlocked = false
    @State private var deletionBlockedReason = ""

    // Phase-2 deferred audit fix: concurrent-edit detection.
    /// Captured when the form first appears. The save() flow compares
    /// this against the server's updated_at — if the server moved
    /// forward in the meantime, another device/user wrote concurrently
    /// and we surface the conflict sheet rather than silently
    /// overwrite.
    @State private var editingBaselineUpdatedAt: Date = Date()
    @State private var conflictServerProject: Project? = nil
    @State private var showConflictAlert = false
    @State private var pendingLocalProject: Project? = nil
    @State private var isCheckingConflict = false

    private var isEditing: Bool { existing != nil }

    /// Phase 9 (lock-on-terminal-state): once a project hits a terminal
    /// status it shouldn't accept field edits. Reports / cost rollups
    /// downstream of the project assume its scope, dates, and contract
    /// value are settled at this point. Editing them post-terminal
    /// would silently shift historical baselines.
    /// Locked states: `.completed`, `.cancelled`. Active states
    /// (`.tendering`, `.awarded`, `.active`, `.onHold`) remain editable.
    /// The lock is iOS-only — server still allows updates so admins
    /// with direct DB access can fix legitimate data errors.
    private var isLocked: Bool {
        guard let s = existing?.status else { return false }
        return s == .completed || s == .cancelled
    }

    /// Reason text surfaced on the lock banner. Status-specific so
    /// the user knows whether they're looking at a closed project
    /// (history) or a cancelled one (won't happen).
    private var lockedReason: String {
        switch existing?.status {
        case .completed: return "Project completed"
        case .cancelled: return "Project cancelled"
        default:         return "Project locked"
        }
    }

    private var selectedClient: Client? {
        guard let id = selectedClientID else { return nil }
        return store.client(id: id)
    }

    private var selectedSite: ClientSite? {
        guard let sid = selectedSiteID else { return nil }
        return selectedClient?.sites.first(where: { $0.id == sid })
    }

    var body: some View {
        NavigationStack {
            Form {
                // Phase 9 (lock-on-terminal-state): completed /
                // cancelled projects render read-only.
                if isLocked {
                    Section {
                        lockedBanner
                    }
                    .listRowInsets(EdgeInsets())
                }

                // ── Client ────────────────────────────────────────
                Section("Client") {
                    Button { showClientPicker = true } label: {
                        HStack {
                            if let client = selectedClient {
                                Circle()
                                    .fill(Color.blue.opacity(0.12))
                                    .frame(width: 30, height: 30)
                                    .overlay(
                                        Text(client.initials)
                                            .font(.caption).bold()
                                            .foregroundColor(.blue)
                                    )
                                Text(client.name).foregroundColor(.primary)
                            } else {
                                Image(systemName: "building.2")
                                    .foregroundColor(.secondary).frame(width: 30)
                                Text("Select Client (optional)")
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }

                    // Site picker — only shown when a CRM client is selected
                    if selectedClientID != nil {
                        Button { showSitePicker = true } label: {
                            HStack {
                                if let site = selectedSite {
                                    Image(systemName: "mappin.circle.fill")
                                        .foregroundColor(.orange).frame(width: 30)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(site.name)
                                            .foregroundColor(.primary).font(.subheadline)
                                        let addr = site.formattedAddress.isEmpty ? site.address : site.formattedAddress
                                        if !addr.isEmpty {
                                            Text(addr).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                        }
                                    }
                                } else {
                                    Image(systemName: "mappin.slash")
                                        .foregroundColor(.secondary).frame(width: 30)
                                    Text("Select Site (optional)")
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    } else {
                        // Fallback: free-text client name for projects not linked to CRM
                        TextField("Client Name *", text: $clientName)
                    }
                }

                // ── Project Info ──────────────────────────────────
                Section("Project Info *") {
                    TextField("Project Name", text: $name)
                    Picker("Status", selection: $status) {
                        ForEach(ProjectStatus.allCases, id: \.self) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    .pickerStyle(.menu)
                }

                // ── Dates ─────────────────────────────────────────
                Section("Dates") {
                    Toggle("Set Start Date", isOn: $hasStartDate)
                    if hasStartDate {
                        DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
                    }
                    Toggle("Set End Date", isOn: $hasEndDate)
                    if hasEndDate {
                        DatePicker("End Date", selection: $endDate, displayedComponents: .date)
                    }
                }

                // ── Financials ────────────────────────────────────
                Section("Financials") {
                    HStack {
                        Text("$")
                        TextField("Contract Value", text: $contractValueString)
                            .keyboardType(.decimalPad)
                    }
                    HStack {
                        Text("$")
                        TextField("Estimated Budget", text: $estimatedBudgetString)
                            .keyboardType(.decimalPad)
                    }
                }

                // ── Notes ─────────────────────────────────────────
                Section("Notes") {
                    TextEditor(text: $notes).frame(minHeight: 80)
                }

                // ── Delete ────────────────────────────────────────
                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            if let project = existing {
                                switch store.deleteProject(project) {
                                case .success:
                                    dismiss()
                                case .failure(let err):
                                    deletionBlockedReason = err.errorDescription ?? "Cannot delete project."
                                    showDeletionBlocked = true
                                }
                            }
                        } label: {
                            Label("Delete Project", systemImage: "trash")
                        }
                    }
                }
            }
            // Form-level disable when locked. Inputs render but are
            // non-interactive — users can READ a closed project, just
            // not change it.
            .disabled(isLocked)
            .navigationTitle(isEditing ? "Edit Project" : "New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    // Re-enable Cancel — form-level .disabled() above
                    // would otherwise grey out the toolbar too.
                    Button("Cancel") { dismiss() }
                        .disabled(false)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isLocked {
                        Label("Locked", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Button("Save") { save() }.bold()
                    }
                }
            }
            .alert("Missing Info", isPresented: $showValidationError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationMessage)
            }
            .alert("Cannot Delete Project", isPresented: $showDeletionBlocked) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deletionBlockedReason)
            }
            .alert("Someone else updated this project", isPresented: $showConflictAlert) {
                Button("Overwrite with my changes", role: .destructive) {
                    if let p = pendingLocalProject {
                        store.upsertProject(p)
                        dismiss()
                    }
                }
                Button("Discard my changes", role: .cancel) {
                    // User accepts the server's version. Their unsaved
                    // edits are lost; the next pull brings the live
                    // server state into the store.
                    Task { await store.refreshAll() }
                    dismiss()
                }
            } message: {
                if let server = conflictServerProject {
                    let by = server.lastModifiedBy.isEmpty ? "another user" : server.lastModifiedBy
                    let when = server.updatedAt.formatted(date: .abbreviated, time: .shortened)
                    Text("\(by) updated this project on the server at \(when), after you opened it. Saving now would overwrite their changes. Choose to keep yours, or discard yours and pull the latest.")
                } else {
                    Text("The server has newer changes than your local copy. Saving now would overwrite them.")
                }
            }
            .sheet(isPresented: $showClientPicker) {
                ClientPickerSheet(selectedClientID: $selectedClientID)
                    .onDisappear {
                        // Auto-fill clientName from selected client
                        if let client = selectedClient {
                            clientName = client.name
                        }
                        // Reset site if client changed
                        if let sid = selectedSiteID,
                           selectedClient?.sites.first(where: { $0.id == sid }) == nil {
                            selectedSiteID = nil
                        }
                    }
            }
            .sheet(isPresented: $showSitePicker) {
                if let clientID = selectedClientID {
                    SitePickerSheet(clientID: clientID, selectedSiteID: $selectedSiteID)
                        .environmentObject(store)
                        .onDisappear {
                            // Auto-fill siteAddress from selected site
                            if let site = selectedSite {
                                _ = site.formattedAddress // resolved for use if needed
                            }
                        }
                }
            }
            .onAppear { populate() }
        }
    }

    // MARK: - Populate

    private func populate() {
        guard let p = existing else { return }
        name                  = p.name
        clientName            = p.clientName
        selectedClientID      = p.clientID
        selectedSiteID        = p.siteID
        status                = p.status
        notes                 = p.notes ?? ""
        if let start = p.startDate { startDate = start; hasStartDate = true }
        if let end   = p.endDate   { endDate   = end;   hasEndDate   = true }
        if let cv    = p.contractValue   { contractValueString   = "\(cv)" }
        if let eb    = p.estimatedBudget { estimatedBudgetString = "\(eb)" }
        // Capture the baseline timestamp now — anything later on
        // the server when we save means concurrent edit.
        editingBaselineUpdatedAt = p.updatedAt
    }

    // MARK: - Locked banner

    /// Phase 9 lock banner — shown at top of the form for completed
    /// / cancelled projects. Status-aware copy so the user knows
    /// which terminal state they're looking at.
    @ViewBuilder
    private var lockedBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundColor(.indigo)
                Text("Locked — \(lockedReason.lowercased())")
                    .font(.subheadline.bold())
                    .foregroundColor(.indigo)
            }
            Text("This project is in a terminal state. Editing scope, dates, or contract value would shift historical baselines used by reports and cost rollups. Reopen by changing the status server-side if you need to edit.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color.indigo.opacity(0.08))
        .cornerRadius(10)
    }

    // MARK: - Save

    private func save() {
        // Phase 9 lock — defensive guard. Toolbar swaps Save for a
        // Locked label when isLocked, but if any code path slips
        // through we abort with a clear message.
        if isLocked {
            validationMessage = "This project is \(lockedReason.lowercased()) and is locked. Change the status server-side to reopen if you need to edit."
            showValidationError = true
            return
        }
        let resolvedName = name.trimmingCharacters(in: .whitespaces)
        guard !resolvedName.isEmpty else {
            validationMessage = "Project name is required."
            showValidationError = true
            return
        }

        // Phase 1 PMI gate: project creation requires a CRM client
        // link, not just a free-text name. Pre-fix you could type a
        // company name with no client picker selection and end up
        // with a project that can't be cross-referenced from CRM
        // reports. The free-text field is now ONLY a fallback for
        // edit paths on legacy projects that already exist with no
        // clientID — new creates must pick from the picker.
        let resolvedClientName = selectedClient?.name ?? clientName.trimmingCharacters(in: .whitespaces)
        guard !resolvedClientName.isEmpty else {
            validationMessage = "Client name is required."
            showValidationError = true
            return
        }
        if existing == nil && selectedClientID == nil {
            validationMessage = "Pick a client from the CRM picker — projects must be linked to a client record so reporting and dashboards can roll up correctly."
            showValidationError = true
            return
        }

        // Site address: resolve from selected site or keep existing.
        // Site itself is a SOFT requirement (not enforced) — many
        // industrial trades create the project before the site walk-
        // through has been done and pick the site after. We surface
        // a warning toast on save when site is missing so the
        // operator knows to circle back, but the save still goes.
        let resolvedSiteAddress = selectedSite.map {
            $0.formattedAddress.isEmpty ? $0.address : $0.formattedAddress
        } ?? existing?.siteAddress
        if existing == nil && selectedSiteID == nil {
            ToastService.shared.warning(
                "Project saved without a site. Pick a site as soon as the location is confirmed — schedule + materials need it."
            )
        }

        var project              = existing ?? Project(name: resolvedName, clientName: resolvedClientName)
        project.name             = resolvedName
        project.clientName       = resolvedClientName
        project.clientID         = selectedClientID
        project.siteID           = selectedSiteID
        project.siteAddress      = resolvedSiteAddress
        project.status           = status
        project.notes            = notes.isEmpty ? nil : notes
        project.startDate        = hasStartDate ? startDate : nil
        project.endDate          = hasEndDate   ? endDate   : nil
        project.contractValue    = Decimal(string: contractValueString)
        project.estimatedBudget  = Decimal(string: estimatedBudgetString)
        project.updatedAt        = Date()
        project.lastModifiedAt   = Date()
        project.syncStatus       = .pending

        // Phase-2 deferred audit fix: only check for conflicts when
        // editing an existing project. Brand-new creates can't
        // conflict (no row to compare against on the server).
        if existing != nil {
            pendingLocalProject = project
            isCheckingConflict  = true
            Task { @MainActor in
                let result = await ConflictDetectionService.shared.checkProject(
                    id:                project.id,
                    baselineUpdatedAt: editingBaselineUpdatedAt
                )
                isCheckingConflict = false
                switch result {
                case .clean, .checkFailed, .notFound:
                    // .checkFailed → don't block the user; let the
                    //  failed-sync banner pick up real failures.
                    // .notFound → row was deleted server-side. Save
                    //  anyway — upsert will recreate. (Edge case;
                    //  the next pull will tombstone if isDeleted.)
                    store.upsertProject(project)
                    dismiss()
                case .conflict(let server):
                    conflictServerProject = server
                    showConflictAlert     = true
                }
            }
        } else {
            store.upsertProject(project)
            dismiss()
        }
    }
}
