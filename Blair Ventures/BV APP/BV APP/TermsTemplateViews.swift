// TermsTemplateViews.swift
// Aski IQ — Terms & Conditions library admin UI, Slice A.
//
// Reachable from Settings → Terms & Conditions (visible to executive,
// manager, office_admin only — gated server-side via RLS and
// client-side at the settings entry).
//
// Slice A scope: list, create, edit, duplicate, archive. NO quote
// integration, NO PDF rendering, NO send-time warnings — those land
// in Slices B and C.

import SwiftUI

// MARK: - List

struct TermsTemplatesListView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var searchText: String = ""
    @State private var categoryFilter: TermsCategory? = nil
    @State private var showArchived: Bool = false
    @State private var draft: EditorDraft? = nil
    @State private var loading: Bool = false

    /// Wraps the template being edited in a sheet plus a flag for
    /// whether it's been persisted yet. Conforming to Identifiable
    /// (via the template's UUID) lets us drive a single .sheet(item:)
    /// for both "+" and duplicate flows — avoids the SwiftUI gotcha
    /// where two .sheet modifiers on one view collide.
    private struct EditorDraft: Identifiable {
        let template: TermsTemplate
        let isNew: Bool
        var id: UUID { template.id }
    }

    /// Templates filtered by the search/category/archived controls
    /// and sorted by (category sort order, then title) — same order
    /// the underlying store accessor uses.
    private var filtered: [TermsTemplate] {
        let base = showArchived ? store.termsTemplates : store.activeTermsTemplates
        return base.filter { t in
            (categoryFilter == nil || t.category == categoryFilter) &&
            (searchText.isEmpty
             || t.title.localizedCaseInsensitiveContains(searchText)
             || t.body.localizedCaseInsensitiveContains(searchText)
             || t.description.localizedCaseInsensitiveContains(searchText))
        }
    }

    private var groupedByCategory: [(TermsCategory, [TermsTemplate])] {
        let groups = Dictionary(grouping: filtered, by: { $0.category })
        return groups
            .map { ($0.key, $0.value) }
            .sorted { $0.0.sortOrder < $1.0.sortOrder }
    }

    var body: some View {
        List {
            // Filter controls
            Section {
                Picker("Category", selection: $categoryFilter) {
                    Text("All").tag(TermsCategory?.none)
                    ForEach(TermsCategory.allCases.sorted(by: { $0.sortOrder < $1.sortOrder })) { c in
                        Label(c.displayName, systemImage: c.icon)
                            .tag(Optional(c))
                    }
                }
                .pickerStyle(.menu)

                Toggle("Show archived", isOn: $showArchived)
            }

            if filtered.isEmpty {
                Section {
                    VStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text(loading ? "Loading…"
                             : (showArchived ? "No archived templates."
                                              : "No templates yet. Tap + to create one."))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }
            } else {
                ForEach(groupedByCategory, id: \.0) { (category, templates) in
                    Section {
                        ForEach(templates) { t in
                            NavigationLink {
                                TermsTemplateEditView(template: t)
                                    .environmentObject(store)
                            } label: {
                                row(t)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if !t.isDeleted {
                                    Button(role: .destructive) {
                                        store.archiveTermsTemplate(t)
                                    } label: {
                                        Label("Archive", systemImage: "archivebox.fill")
                                    }
                                }
                                Button {
                                    let copy = store.duplicateTermsTemplate(t)
                                    // Duplicate is already persisted by
                                    // duplicateTermsTemplate; open the
                                    // editor so the user can rename.
                                    draft = EditorDraft(template: copy, isNew: false)
                                } label: {
                                    Label("Duplicate", systemImage: "doc.on.doc.fill")
                                }
                                .tint(.indigo)
                            }
                        }
                    } header: {
                        HStack {
                            Image(systemName: category.icon)
                                .foregroundColor(category.color)
                            Text(category.displayName.uppercased())
                                .font(.caption.bold())
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "Search title or body")
        .navigationTitle("Terms & Conditions")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    if let cid = store.currentCompanyID {
                        draft = EditorDraft(
                            template: TermsTemplate(companyID: cid),
                            isNew: true
                        )
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task {
            // Pull on first appearance so a freshly-launched app shows
            // the latest templates without forcing the user back to the
            // root sync. Cheap query — small table, single tenant.
            loading = true
            await SyncEngine.shared.pullTermsTemplates()
            loading = false
        }
        .sheet(item: $draft) { d in
            NavigationStack {
                TermsTemplateEditView(template: d.template, isNewDraft: d.isNew)
                    .environmentObject(store)
            }
        }
    }

    @ViewBuilder
    private func row(_ t: TermsTemplate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: t.category.icon)
                .font(.title3)
                .foregroundColor(t.category.color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(t.title)
                        .font(.subheadline).bold()
                        .foregroundColor(.primary)
                    if t.isDefault {
                        Text("DEFAULT")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.green.opacity(0.18))
                            .foregroundColor(.green)
                            .cornerRadius(3)
                    }
                    if !t.isActive {
                        Text("ARCHIVED")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.gray.opacity(0.18))
                            .foregroundColor(.gray)
                            .cornerRadius(3)
                    }
                    if t.syncStatus != .synced {
                        Image(systemName: "icloud.slash")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
                if !t.description.isEmpty {
                    Text(t.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    Text("v\(t.version)")
                        .font(.caption2)
                        .fontDesign(.monospaced)
                        .foregroundColor(.secondary)
                    if !t.appliesToServiceTypes.isEmpty {
                        Text(t.appliesToServiceTypes.map { $0.displayName }.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Edit / Create

struct TermsTemplateEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var template: TermsTemplate
    /// True when presented from the "+" button (fresh draft never
    /// saved). Drives the toolbar — sheet presentations show Save +
    /// Cancel; navigation-stack presentations show only Save.
    private let isNewDraft: Bool

    @State private var showValidationError: Bool = false
    @State private var validationMessage: String = ""
    @State private var showArchiveConfirm: Bool = false

    init(template: TermsTemplate, isNewDraft: Bool = false) {
        self._template = State(initialValue: template)
        self.isNewDraft = isNewDraft
    }

    var body: some View {
        Form {
            Section("Template Info") {
                TextField("Title", text: $template.title)
                    .autocorrectionDisabled()

                Picker("Category", selection: $template.category) {
                    ForEach(TermsCategory.allCases.sorted(by: { $0.sortOrder < $1.sortOrder })) { c in
                        Label(c.displayName, systemImage: c.icon).tag(c)
                    }
                }

                TextField("Internal description (admin-only)", text: $template.description, axis: .vertical)
                    .lineLimit(2...4)
            }

            Section {
                TextEditor(text: $template.body)
                    .frame(minHeight: 220)
                    .font(.body)
            } header: {
                Text("Body")
            } footer: {
                Text("Editing the body or title will bump this template's version on save. Already-sent quotes keep their original wording.")
                    .font(.caption)
            }

            Section {
                ForEach(ServiceType.allCases) { st in
                    let on = template.appliesToServiceTypes.contains(st)
                    Button {
                        toggle(st)
                    } label: {
                        HStack {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(on ? .green : .secondary)
                            Text(st.displayName)
                                .foregroundColor(.primary)
                            Spacer()
                        }
                    }
                }
            } header: {
                Text("Auto-suggest for Service Types")
            } footer: {
                Text("This template will appear in the Suggested section of the quote terms picker when a quote includes line items in the selected service type(s). Used by Slice C.")
                    .font(.caption)
            }

            Section {
                Toggle("Default template (auto-attach to new quotes)",
                       isOn: $template.isDefault)
                Toggle("Active (visible in quote picker)",
                       isOn: $template.isActive)
            } header: {
                Text("Status")
            }

            if !isNewDraft {
                Section {
                    LabeledContent("Version", value: "v\(template.version)")
                    LabeledContent("Last updated",
                                   value: template.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Sync status", value: template.syncStatus.rawValue.capitalized)
                }

                Section {
                    Button(role: .destructive) {
                        showArchiveConfirm = true
                    } label: {
                        Label(template.isDeleted ? "Already archived" : "Archive Template",
                              systemImage: "archivebox.fill")
                    }
                    .disabled(template.isDeleted)
                }
            }
        }
        .navigationTitle(isNewDraft ? "New Template" : "Edit Template")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNewDraft {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
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
        .alert("Archive this template?",
               isPresented: $showArchiveConfirm,
               actions: {
            Button("Archive", role: .destructive) {
                store.archiveTermsTemplate(template)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }, message: {
            Text("Archived templates stop appearing in the quote picker but remain attached to historical quotes that already used them.")
        })
    }

    private func toggle(_ st: ServiceType) {
        if let i = template.appliesToServiceTypes.firstIndex(of: st) {
            template.appliesToServiceTypes.remove(at: i)
        } else {
            template.appliesToServiceTypes.append(st)
        }
    }

    private func save() {
        let trimmedTitle = template.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody  = template.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            validationMessage = "Title is required."
            showValidationError = true
            return
        }
        guard !trimmedBody.isEmpty else {
            validationMessage = "Body is required. Paste or type the actual T&C text."
            showValidationError = true
            return
        }
        template.title = trimmedTitle
        template.body  = trimmedBody
        store.upsertTermsTemplate(template)
        dismiss()
    }
}
