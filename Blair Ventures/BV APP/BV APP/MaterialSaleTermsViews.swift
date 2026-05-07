// MaterialSaleTermsViews.swift
// Aski IQ — Terms & Conditions UI for Material Sales (Path-A clone of QuoteTermsViews).
//
// Material Sale–side UI:
//   • MaterialSaleTermsSection      — inline section in MaterialSaleCreateEditView
//   • MaterialSaleTermsPickerSheet  — multi-select template picker
//   • MaterialSaleCustomTermSheet   — ad-hoc term editor
//   • MaterialSaleTermsPreviewSheet — read-only render of attached terms
//
// Read-only mode: gated by `MaterialSaleStatus.termsAreReadOnly`.
//
// CRITICAL GUARDRAIL
// Selecting / opening / closing terms in this UI MUST NOT trigger
// any workflow status change on the parent sale.

import SwiftUI

// MARK: - Inline Section

struct MaterialSaleTermsSection: View {
    let saleID: UUID
    let readOnly: Bool

    var onPresentPicker:  () -> Void = {}
    var onPresentCustom:  () -> Void = {}
    var onPresentPreview: () -> Void = {}

    @EnvironmentObject var store: AppStore

    private var terms: [MaterialSaleTerm] {
        store.materialSaleTerms(for: saleID)
    }

    var body: some View {
        Section {
            sectionContent
        } header: {
            sectionHeader
        } footer: {
            sectionFooter
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        if terms.isEmpty {
            Text("No Terms & Conditions attached. Tap Add Terms to choose from the library or Add Custom for one-off wording.")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            termsList
        }

        if !readOnly {
            Button { onPresentPicker() } label: {
                Label("Add Terms from Library", systemImage: "doc.text.fill")
            }
            Button { onPresentCustom() } label: {
                Label("Add Custom Term", systemImage: "plus.bubble.fill")
            }
        }

        if !terms.isEmpty {
            Button { onPresentPreview() } label: {
                Label("Preview Terms", systemImage: "eye.fill")
            }
        }
    }

    @ViewBuilder
    private var termsList: some View {
        if readOnly {
            ForEach(terms) { t in
                MaterialSaleTermsRow(term: t)
            }
        } else {
            ForEach(terms) { t in
                MaterialSaleTermsRow(term: t)
            }
            .onMove(perform: move)
            .onDelete(perform: delete)
        }
    }

    @ViewBuilder
    private var sectionHeader: some View {
        HStack {
            Text("Terms & Conditions")
            Spacer()
            if readOnly {
                Label("Locked", systemImage: "lock.fill")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var sectionFooter: some View {
        if readOnly {
            Text("This sale is paid or cancelled — attached terms are now locked.")
                .font(.caption)
        } else if !terms.isEmpty {
            Text("Drag rows to reorder. Swipe left to remove. Snapshot text was captured when each term was attached, so edits to master templates won't affect this sale.")
                .font(.caption)
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var working = terms
        working.move(fromOffsets: source, toOffset: destination)
        store.reorderMaterialSaleTerms(working)
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets {
            store.deleteMaterialSaleTerm(terms[i])
        }
    }
}

private struct MaterialSaleTermsRow: View {
    let term: MaterialSaleTerm

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: term.isCustom ? "doc.text" : "doc.richtext")
                .foregroundColor(term.isCustom ? .orange : .blue)
                .font(.title3)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                titleRow
                Text(term.bodySnapshot)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var titleRow: some View {
        HStack(spacing: 6) {
            Text(term.titleSnapshot)
                .font(.subheadline).bold()
                .lineLimit(1)
            if term.isCustom {
                Text("CUSTOM")
                    .font(.caption2.bold())
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.18))
                    .foregroundColor(.orange)
                    .cornerRadius(3)
            } else if let v = term.versionSnapshot {
                Text("v\(v)")
                    .font(.caption2)
                    .fontDesign(.monospaced)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Picker Sheet

struct MaterialSaleTermsPickerSheet: View {
    let saleID: UUID

    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var searchText: String = ""
    @State private var categoryFilter: TermsCategory? = nil
    @State private var selectedIDs: Set<UUID> = []

    private var alreadyAttachedTemplateIDs: Set<UUID> {
        Set(store.materialSaleTerms(for: saleID).compactMap { $0.templateID })
    }

    private var visible: [TermsTemplate] {
        store.activeTermsTemplates.filter { t in
            (categoryFilter == nil || t.category == categoryFilter) &&
            (searchText.isEmpty
             || t.title.localizedCaseInsensitiveContains(searchText)
             || t.body.localizedCaseInsensitiveContains(searchText))
        }
    }

    private var grouped: [(TermsCategory, [TermsTemplate])] {
        Dictionary(grouping: visible, by: { $0.category })
            .map { ($0.key, $0.value) }
            .sorted { $0.0.sortOrder < $1.0.sortOrder }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Category", selection: $categoryFilter) {
                        Text("All").tag(TermsCategory?.none)
                        ForEach(TermsCategory.allCases.sorted(by: { $0.sortOrder < $1.sortOrder })) { c in
                            Label(c.displayName, systemImage: c.icon).tag(Optional(c))
                        }
                    }
                    .pickerStyle(.menu)
                }

                if visible.isEmpty {
                    Section {
                        Text(searchText.isEmpty
                             ? "No active templates. Ask an admin to add one in Settings → Terms & Conditions."
                             : "No matches.")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }

                ForEach(grouped, id: \.0) { (category, templates) in
                    Section {
                        ForEach(templates) { t in
                            row(t)
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
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, prompt: "Search title or body")
            .navigationTitle("Add Terms")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add (\(selectedIDs.count))") {
                        attach()
                    }
                    .bold()
                    .disabled(selectedIDs.isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ t: TermsTemplate) -> some View {
        let alreadyAttached = alreadyAttachedTemplateIDs.contains(t.id)
        let isSelected = selectedIDs.contains(t.id)
        Button {
            if alreadyAttached { return }
            if isSelected { selectedIDs.remove(t.id) }
            else          { selectedIDs.insert(t.id) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: alreadyAttached
                      ? "checkmark.circle.fill"
                      : (isSelected ? "checkmark.circle.fill" : "circle"))
                    .foregroundColor(alreadyAttached ? .green
                                     : (isSelected ? .blue : .secondary))
                    .font(.title3)
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
                        Text("v\(t.version)")
                            .font(.caption2)
                            .fontDesign(.monospaced)
                            .foregroundColor(.secondary)
                    }
                    Text(t.body)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                    if alreadyAttached {
                        Text("Already attached to this sale")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .disabled(alreadyAttached)
    }

    /// Attach selected templates and dismiss. NEVER triggers any
    /// workflow status change on the parent sale.
    private func attach() {
        let toAdd = store.activeTermsTemplates.filter { selectedIDs.contains($0.id) }
        for t in toAdd {
            store.attachTermsTemplateToMaterialSale(t, saleID: saleID)
        }
        dismiss()
    }
}

// MARK: - Custom Term Sheet

struct MaterialSaleCustomTermSheet: View {
    let saleID: UUID
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var bodyText: String = ""
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("e.g. Site-Specific Delivery", text: $title)
                }
                Section {
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 220)
                } header: {
                    Text("Body")
                } footer: {
                    Text("This term applies only to this sale. To make it reusable across sales, ask an admin to add it as a template in Settings → Terms & Conditions.")
                        .font(.caption)
                }
            }
            .navigationTitle("Add Custom Term")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }.bold()
                }
            }
            .alert("Missing Info", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private func save() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            errorMessage = "Title is required."
            showError = true
            return
        }
        guard !b.isEmpty else {
            errorMessage = "Body is required."
            showError = true
            return
        }
        store.addCustomMaterialSaleTerm(saleID: saleID, title: t, body: b)
        dismiss()
    }
}

// MARK: - Preview Sheet

struct MaterialSaleTermsPreviewSheet: View {
    let saleID: UUID
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private var terms: [MaterialSaleTerm] {
        store.materialSaleTerms(for: saleID)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if terms.isEmpty {
                        Text("No terms attached.")
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        ForEach(terms) { t in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Text(t.titleSnapshot)
                                        .font(.title3).bold()
                                    if t.isCustom {
                                        Text("CUSTOM")
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Color.orange.opacity(0.18))
                                            .foregroundColor(.orange)
                                            .cornerRadius(4)
                                    } else if let v = t.versionSnapshot {
                                        Text("v\(v)")
                                            .font(.caption)
                                            .fontDesign(.monospaced)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Text(t.bodySnapshot)
                                    .font(.body)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal)
                            Divider().padding(.horizontal)
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Terms & Conditions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
