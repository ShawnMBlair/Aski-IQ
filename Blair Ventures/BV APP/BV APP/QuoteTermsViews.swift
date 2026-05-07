// QuoteTermsViews.swift
// Aski IQ — Terms & Conditions library, Slice B.
//
// Quote-side UI:
//   • QuoteTermsSection      — inline section in QuoteCreateView
//   • QuoteTermsPickerSheet  — multi-select template picker
//   • QuoteCustomTermSheet   — ad-hoc term editor
//   • QuoteTermsPreviewSheet — read-only render of attached terms
//
// Read-only mode: when a quote's status is .sent / .accepted / .declined
// (per QuoteStatus.termsAreReadOnly) the section drops to preview-only
// — no add/remove/reorder/edit. Picker and custom-term buttons are hidden.

import SwiftUI

// MARK: - Inline Section

struct QuoteTermsSection: View {
    let quoteID: UUID
    /// Drives the read-only state. Caller computes whether the quote
    /// is in a status that should freeze terms (typically
    /// `quote.status.termsAreReadOnly || quote.expiryDate < Date()`).
    let readOnly: Bool
    /// Slice C: current line items on the quote being edited. Used by
    /// the picker to compute the "Suggested for this quote" section.
    /// Defaults to empty (suggested section just stays hidden).
    var lineItems: [CostCodeItem] = []

    /// Critical workflow fix: parent provides closures for opening the
    /// terms sheets. Pre-fix this section attached its own .sheet
    /// modifiers, which collided with QuoteCreateView's parent .sheet
    /// modifiers (productPicker, sendReview) — SwiftUI's nested-sheet
    /// behavior is unreliable, the user reported the picker auto-
    /// dismissing repeatedly. Now QuoteCreateView owns one enum-driven
    /// sheet at the top level; this section just calls back to request
    /// presentation.
    var onPresentPicker:  () -> Void = {}
    var onPresentCustom:  () -> Void = {}
    var onPresentPreview: () -> Void = {}

    @EnvironmentObject var store: AppStore

    private var terms: [QuoteTerm] {
        store.quoteTerms(for: quoteID)
    }

    // body is split into small @ViewBuilder pieces because SwiftUI's
    // type-checker hits "expression too complex" with this much
    // branching inline. Each helper is independently type-checkable.

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
        // Split on readOnly because the ternary `readOnly ? nil : move`
        // confuses Swift's type-checker — it can't infer the
        // ((IndexSet, Int) -> Void)? type from a method reference + nil.
        if readOnly {
            ForEach(terms) { t in
                QuoteTermsRow(term: t)
            }
        } else {
            ForEach(terms) { t in
                QuoteTermsRow(term: t)
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
            Text("This quote has been sent or completed — attached terms are now locked. Use Preview to view; create a new revision to modify.")
                .font(.caption)
        } else if !terms.isEmpty {
            Text("Drag rows to reorder. Swipe left to remove. Snapshot text was captured when each term was attached, so edits to master templates won't affect this quote.")
                .font(.caption)
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var working = terms
        working.move(fromOffsets: source, toOffset: destination)
        store.reorderQuoteTerms(working)
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets {
            store.deleteQuoteTerm(terms[i])
        }
    }
}

/// Single row in the Terms & Conditions section. Extracted to its own
/// view so the parent's `body` stays simple enough for SwiftUI's
/// type-checker.
private struct QuoteTermsRow: View {
    let term: QuoteTerm

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

struct QuoteTermsPickerSheet: View {
    let quoteID: UUID
    /// Slice C: current quote line items, used to compute the Suggested
    /// section. Empty array → Suggested section is hidden.
    var lineItems: [CostCodeItem] = []

    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var searchText: String = ""
    @State private var categoryFilter: TermsCategory? = nil
    @State private var selectedIDs: Set<UUID> = []

    /// Templates already attached (matched by templateID) — surfaced
    /// in the picker so the user can see their picks rather than
    /// double-attaching.
    private var alreadyAttachedTemplateIDs: Set<UUID> {
        Set(store.quoteTerms(for: quoteID).compactMap { $0.templateID })
    }

    /// Slice C: templates suggested for the quote's line-item categories.
    /// Empty when (a) no line items, (b) no line items have tagged
    /// service types, or (c) all matching templates are already attached.
    private var suggested: [TermsTemplate] {
        let serviceTypes = store.serviceTypes(forLineItems: lineItems)
        let attached = alreadyAttachedTemplateIDs
        return store.suggestedTermsTemplates(
            forServiceTypes: serviceTypes,
            excludingTemplateIDs: attached
        )
        .filter { t in
            (categoryFilter == nil || t.category == categoryFilter) &&
            (searchText.isEmpty
             || t.title.localizedCaseInsensitiveContains(searchText)
             || t.body.localizedCaseInsensitiveContains(searchText))
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
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
        // Exclude the suggested templates from the by-category grouping
        // so they don't appear twice on screen. They're still selectable
        // from the Suggested section above.
        let suggestedIDs = Set(suggested.map { $0.id })
        return Dictionary(grouping: visible.filter { !suggestedIDs.contains($0.id) }, by: { $0.category })
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

                // Slice C: Suggested section — pinned at the top when
                // the quote's line items match templates by service type.
                if !suggested.isEmpty {
                    Section {
                        ForEach(suggested) { t in
                            row(t)
                        }
                    } header: {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundColor(.purple)
                            Text("SUGGESTED FOR THIS QUOTE")
                                .font(.caption.bold())
                        }
                    } footer: {
                        Text("Surfaced because line items in this quote use cost codes tagged with matching service types.")
                            .font(.caption)
                    }
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
                        Text("Already attached to this quote")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .disabled(alreadyAttached)
    }

    private func attach() {
        let toAdd = store.activeTermsTemplates.filter { selectedIDs.contains($0.id) }
        for t in toAdd {
            store.attachTermsTemplateToQuote(t, quoteID: quoteID)
        }
        dismiss()
    }
}

// MARK: - Custom Term Sheet

struct QuoteCustomTermSheet: View {
    let quoteID: UUID
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
                    TextField("e.g. Site-Specific Permitting", text: $title)
                }
                Section {
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 220)
                } header: {
                    Text("Body")
                } footer: {
                    Text("This term applies only to this quote. To make it reusable across quotes, ask an admin to add it as a template in Settings → Terms & Conditions.")
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
        store.addCustomQuoteTerm(quoteID: quoteID, title: t, body: b)
        dismiss()
    }
}

// MARK: - Preview Sheet

struct QuoteTermsPreviewSheet: View {
    let quoteID: UUID
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private var terms: [QuoteTerm] {
        store.quoteTerms(for: quoteID)
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
