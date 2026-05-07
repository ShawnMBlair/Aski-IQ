// FormsHubView.swift
// FieldOS – Forms Hub (Submitted / Library / Archive)
// Mirrors Salus Pro forms navigation

import SwiftUI

// MARK: - Forms Hub

struct FormsHubView: View {
    @EnvironmentObject var store: AppStore
    @State private var selectedTab: FormsTab = .submitted

    enum FormsTab: String, CaseIterable {
        case submitted = "Submitted"
        case library   = "Library"
        case archive   = "Archive"

        var icon: String {
            switch self {
            case .submitted: return "tray.full.fill"
            case .library:   return "books.vertical.fill"
            case .archive:   return "archivebox.fill"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab bar
                HStack(spacing: 0) {
                    ForEach(FormsTab.allCases, id: \.self) { tab in
                        FormsTabButton(
                            tab: tab,
                            isSelected: selectedTab == tab,
                            badge: badge(for: tab)
                        ) {
                            selectedTab = tab
                        }
                    }
                }
                .background(Color(.systemBackground))

                Divider()

                // Content
                switch selectedTab {
                case .submitted: SubmittedFormsView()
                case .library:   FormsLibraryView()
                case .archive:   ArchivedFormsView()
                }
            }
            .navigationTitle("Forms")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if selectedTab == .library {
                        NavigationLink {
                            FormTemplateBuilderView()
                        } label: {
                            Image(systemName: "plus")
                        }
                    } else if selectedTab == .submitted {
                        NavigationLink {
                            FormPickerSheet()
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                    }
                }
            }
        }
    }

    private func badge(for tab: FormsTab) -> Int? {
        switch tab {
        case .submitted:
            let drafts = store.formSubmissions.filter { $0.isDraft && !$0.isArchived }.count
            return drafts > 0 ? drafts : nil
        case .library:
            return nil
        case .archive:
            return nil
        }
    }
}

// MARK: - Tab Button

private struct FormsTabButton: View {
    let tab: FormsHubView.FormsTab
    let isSelected: Bool
    let badge: Int?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: tab.icon)
                        .font(.system(size: 14))
                    Text(tab.rawValue)
                        .font(.subheadline)
                        .fontWeight(isSelected ? .semibold : .regular)
                    if let b = badge {
                        Text("\(b)")
                            .font(.caption2).bold()
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                }
                .foregroundColor(isSelected ? .blue : .secondary)

                Rectangle()
                    .fill(isSelected ? Color.blue : Color.clear)
                    .frame(height: 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }
}

// MARK: - Submitted Forms View

struct SubmittedFormsView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var pagination = PaginationState(pageSize: 25)
    @State private var searchText = ""
    @State private var filterStatus: SubmissionFilter = .all
    @State private var filterLinkType: FormLinkType? = nil   // nil = all types
    @State private var filterProjectID: UUID? = nil
    @State private var selectedSubmission: FormSubmission? = nil

    enum SubmissionFilter: String, CaseIterable {
        case all = "All"
        case drafts = "Drafts"
        case signed = "Signed"
        case submitted = "Submitted"
    }

    private var linkedProjects: [Project] {
        let ids = Set(store.formSubmissions.compactMap { $0.projectID })
        return store.projects.filter { ids.contains($0.id) }.sorted { $0.name < $1.name }
    }

    private var submissions: [FormSubmission] {
        store.formSubmissions
            .filter { !$0.isArchived }
            .filter { sub in
                switch filterStatus {
                case .all:       return true
                case .drafts:    return sub.isDraft
                case .signed:    return sub.isSigned && !sub.isDraft
                case .submitted: return !sub.isDraft && !sub.isSigned
                }
            }
            .filter { sub in
                if let lt = filterLinkType { return sub.linkType == lt }
                return true
            }
            .filter { sub in
                if let pid = filterProjectID { return sub.projectID == pid }
                return true
            }
            .filter { sub in
                guard !searchText.isEmpty else { return true }
                let templateName = store.formTemplates.first { $0.id == sub.templateID }?.name ?? ""
                return sub.submittedBy.localizedCaseInsensitiveContains(searchText)
                    || templateName.localizedCaseInsensitiveContains(searchText)
                    || (sub.linkedName ?? "").localizedCaseInsensitiveContains(searchText)
            }
            .sorted { ($0.submittedAt ?? $0.createdAt) > ($1.submittedAt ?? $1.createdAt) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search + filter
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Search by form name or submitter…", text: $searchText)
                }
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)

                // Status filter
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(SubmissionFilter.allCases, id: \.self) { f in
                            FilterPill(label: f.rawValue, isSelected: filterStatus == f) {
                                filterStatus = f
                            }
                        }
                    }
                }

                // Link type filter
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterPill(label: "All Links", isSelected: filterLinkType == nil) {
                            filterLinkType = nil
                            filterProjectID = nil
                        }
                        ForEach(FormLinkType.allCases.filter { $0 != .none }, id: \.self) { lt in
                            FilterPill(
                                label: lt.displayName,
                                isSelected: filterLinkType == lt
                            ) {
                                filterLinkType = filterLinkType == lt ? nil : lt
                                if filterLinkType != .project { filterProjectID = nil }
                            }
                        }
                    }
                }

                // Project sub-filter (only when Project link type selected)
                if filterLinkType == .project && !linkedProjects.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            FilterPill(label: "All Projects", isSelected: filterProjectID == nil) {
                                filterProjectID = nil
                            }
                            ForEach(linkedProjects) { project in
                                FilterPill(label: project.name, isSelected: filterProjectID == project.id) {
                                    filterProjectID = filterProjectID == project.id ? nil : project.id
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if submissions.isEmpty {
                emptyState
            } else {
                List {
                    // Stats row
                    Section {
                        SubmissionStatsRow()
                    }

                    Section("\(submissions.count) form\(submissions.count == 1 ? "" : "s")") {
                        ForEach(Array(submissions.prefix(pagination.displayLimit))) { submission in
                            SubmittedFormRow(submission: submission)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedSubmission = submission }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        archiveSubmission(submission)
                                    } label: {
                                        Label("Archive", systemImage: "archivebox")
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    if submission.isDraft {
                                        NavigationLink {
                                            if let template = store.formTemplates.first(where: { $0.id == submission.templateID }) {
                                                FormSubmissionView(template: template)
                                            }
                                        } label: {
                                            Label("Resume", systemImage: "pencil")
                                        }
                                        .tint(.blue)
                                    }
                                }
                        }
                        LoadMoreFooter(
                            showing: min(pagination.displayLimit, submissions.count),
                            total:   submissions.count
                        ) { pagination.loadMore() }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .sheet(item: $selectedSubmission) { sub in
            FormSubmissionDetailView(submission: sub)
        }
        .onChange(of: searchText)     { _ in pagination.reset() }
        .onChange(of: filterStatus)   { _ in pagination.reset() }
        .onChange(of: filterLinkType) { pagination.reset() }
        .onChange(of: filterProjectID){ _ in pagination.reset() }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 52)).foregroundColor(.secondary)
            Text(filterStatus == .all ? "No forms submitted yet." : "No \(filterStatus.rawValue.lowercased()) forms.")
                .font(.headline)
            Text("Tap  ✏️  to fill out a form from the Library.")
                .font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            NavigationLink("Open Library") {
                FormsLibraryView()
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
    }

    private func archiveSubmission(_ sub: FormSubmission) {
        if let idx = store.formSubmissions.firstIndex(where: { $0.id == sub.id }) {
            var updated = store.formSubmissions[idx]
            updated.isArchived = true
            updated.syncStatus = .pending
            store.upsertFormSubmission(updated)
        }
    }
}

// MARK: - Submission Stats Row

private struct SubmissionStatsRow: View {
    @EnvironmentObject var store: AppStore

    private var total: Int   { store.formSubmissions.filter { !$0.isDraft && !$0.isArchived }.count }
    private var drafts: Int  { store.formSubmissions.filter { $0.isDraft && !$0.isArchived }.count }
    private var signed: Int  { store.formSubmissions.filter { $0.isSigned && !$0.isArchived }.count }

    private var todayCount: Int {
        store.formSubmissions.filter {
            guard let d = $0.submittedAt else { return false }
            return Calendar.current.isDateInToday(d) && !$0.isArchived
        }.count
    }

    var body: some View {
        HStack(spacing: 0) {
            statCell(value: "\(total)",    label: "Total",   color: .blue)
            Divider().frame(height: 36)
            statCell(value: "\(todayCount)", label: "Today", color: .green)
            Divider().frame(height: 36)
            statCell(value: "\(drafts)",   label: "Drafts",  color: .orange)
            Divider().frame(height: 36)
            statCell(value: "\(signed)",   label: "Signed",  color: .purple)
        }
    }

    private func statCell(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3).bold().foregroundColor(color)
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

// MARK: - Submitted Form Row

struct SubmittedFormRow: View {
    let submission: FormSubmission
    @EnvironmentObject var store: AppStore

    private var templateName: String {
        store.formTemplates.first { $0.id == submission.templateID }?.name ?? "Unknown Form"
    }
    private var templateCategory: String? {
        store.formTemplates.first { $0.id == submission.templateID }?.category
    }
    private var projectName: String? {
        submission.projectID.flatMap { store.project(id: $0) }?.name
    }

    var body: some View {
        HStack(spacing: 14) {
            // Status icon
            ZStack {
                Circle()
                    .fill(rowColor.opacity(0.12))
                    .frame(width: 46, height: 46)
                Image(systemName: rowIcon)
                    .foregroundColor(rowColor)
                    .font(.system(size: 18))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(templateName)
                    .font(.subheadline).bold()
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let cat = templateCategory {
                        Text(cat)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.blue.opacity(0.1))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                    Text(submission.submittedBy)
                        .font(.caption).foregroundColor(.secondary)
                }

                // Link badge
                if submission.linkType != .none {
                    HStack(spacing: 4) {
                        Image(systemName: submission.linkType.icon)
                            .font(.caption2)
                        Text(submission.linkDisplayName)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .foregroundColor(linkColor(submission.linkType))
                } else if let proj = projectName {
                    Label(proj, systemImage: "mappin.circle")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 5) {
                if let date = submission.submittedAt ?? (submission.isDraft ? Optional(submission.createdAt) : nil) {
                    Text(date.shortDate)
                        .font(.caption2).foregroundColor(.secondary)
                }
                statusBadge
            }
        }
        .padding(.vertical, 4)
    }

    private var rowIcon: String {
        if submission.isDraft        { return "doc.badge.clock" }
        if submission.isSigned       { return "checkmark.seal.fill" }
        return "doc.text.fill"
    }
    private var rowColor: Color {
        if submission.isDraft        { return .orange }
        if submission.isSigned       { return .green }
        return .blue
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
    private var statusBadge: some View {
        let (label, color): (String, Color) = {
            if submission.isDraft  { return ("Draft", .orange) }
            if submission.isSigned { return ("Signed", .green) }
            return ("Submitted", .blue)
        }()
        return Text(label)
            .font(.caption2).bold()
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.12))
            .foregroundColor(color)
            .cornerRadius(5)
    }
}

// MARK: - Forms Library View

struct FormsLibraryView: View {
    @EnvironmentObject var store: AppStore
    @State private var searchText = ""
    @State private var selectedCategory: String? = nil
    @State private var showCreate = false
    @State private var selectedTemplate: FormTemplate? = nil
    @State private var showUseForm = false
    @State private var templateToUse: FormTemplate? = nil

    private var categories: [String] {
        Array(Set(store.formTemplates.compactMap { $0.category })).sorted()
    }

    private var templates: [FormTemplate] {
        store.formTemplates
            .filter { !$0.isArchived }
            .filter { selectedCategory == nil || $0.category == selectedCategory }
            .filter {
                searchText.isEmpty ||
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                ($0.category ?? "").localizedCaseInsensitiveContains(searchText)
            }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search Form Library…", text: $searchText)
            }
            .padding(10)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
            .padding(.horizontal)
            .padding(.top, 12)

            // Category pills
            if !categories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterPill(label: "All", isSelected: selectedCategory == nil) {
                            selectedCategory = nil
                        }
                        ForEach(categories, id: \.self) { cat in
                            FilterPill(label: cat, isSelected: selectedCategory == cat) {
                                selectedCategory = selectedCategory == cat ? nil : cat
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
            }

            Divider()

            if templates.isEmpty {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 48)).foregroundColor(.secondary)
                    Text("No templates yet.")
                        .font(.headline)
                    Text("Build your first form template to get started.")
                        .font(.subheadline).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Create Template") { showCreate = true }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
                Spacer()
            } else {
                List {
                    Section("\(templates.count) template\(templates.count == 1 ? "" : "s")") {
                        ForEach(templates) { template in
                            LibraryTemplateRow(template: template)
                                .swipeActions(edge: .trailing) {
                                    // Archive template
                                    Button {
                                        archiveTemplate(template)
                                    } label: {
                                        Label("Archive", systemImage: "archivebox")
                                    }
                                    .tint(.orange)

                                    // Duplicate
                                    Button {
                                        duplicateTemplate(template)
                                    } label: {
                                        Label("Duplicate", systemImage: "doc.on.doc")
                                    }
                                    .tint(.blue)
                                }
                                .swipeActions(edge: .leading) {
                                    // Quick-use — fill out form
                                    Button {
                                        templateToUse = template
                                        showUseForm = true
                                    } label: {
                                        Label("Fill Out", systemImage: "square.and.pencil")
                                    }
                                    .tint(.green)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { selectedTemplate = template }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .sheet(isPresented: $showCreate) {
            FormTemplateBuilderView()
        }
        .sheet(item: $selectedTemplate) { template in
            FormTemplateBuilderView(existing: template)
        }
        .sheet(isPresented: $showUseForm) {
            if let template = templateToUse {
                FormSubmissionView(template: template)
            }
        }
        .onAppear { FormTemplateSeed.seedIfNeeded(into: store) }
    }

    private func archiveTemplate(_ t: FormTemplate) {
        if let idx = store.formTemplates.firstIndex(where: { $0.id == t.id }) {
            var updated = store.formTemplates[idx]
            updated.isArchived = true
            updated.syncStatus = .pending
            store.upsertFormTemplate(updated)
        }
    }

    private func duplicateTemplate(_ t: FormTemplate) {
        var copy = t
        copy.id = UUID()
        copy.name = t.name + " (Copy)"
        copy.createdAt = Date()
        copy.updatedAt = Date()
        copy.syncStatus = .pending
        store.upsertFormTemplate(copy)
    }
}

// MARK: - Library Template Row

struct LibraryTemplateRow: View {
    let template: FormTemplate
    @EnvironmentObject var store: AppStore

    private var submissionCount: Int {
        store.formSubmissions.filter { $0.templateID == template.id && !$0.isDraft }.count
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 46, height: 46)
                Image(systemName: "doc.text.fill")
                    .foregroundColor(.blue)
                    .font(.system(size: 18))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(template.name)
                    .font(.subheadline).bold()
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if let cat = template.category {
                        Text(cat)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.blue.opacity(0.1))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                    let inputCount = template.fields.filter { !$0.type.isLayoutOnly }.count
                    Text("\(inputCount) fields")
                        .font(.caption).foregroundColor(.secondary)
                    if template.requiresSignature {
                        Image(systemName: "signature")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }

                if submissionCount > 0 {
                    Text("\(submissionCount) submission\(submissionCount == 1 ? "" : "s")")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("v\(template.version)")
                    .font(.caption2).foregroundColor(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Archived Forms View

struct ArchivedFormsView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var pagination = PaginationState(pageSize: 25)
    @State private var archivedTab: ArchivedTab = .submissions

    enum ArchivedTab: String, CaseIterable {
        case submissions = "Submissions"
        case templates   = "Templates"
    }

    private var archivedSubmissions: [FormSubmission] {
        store.formSubmissions
            .filter { $0.isArchived }
            .sorted { ($0.submittedAt ?? $0.createdAt) > ($1.submittedAt ?? $1.createdAt) }
    }

    private var archivedTemplates: [FormTemplate] {
        store.formTemplates
            .filter { $0.isArchived }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Archived", selection: $archivedTab) {
                ForEach(ArchivedTab.allCases, id: \.self) { t in Text(t.rawValue).tag(t) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            if archivedTab == .submissions {
                archivedSubmissionsList
            } else {
                archivedTemplatesList
            }
        }
    }

    private var archivedSubmissionsList: some View {
        Group {
            if archivedSubmissions.isEmpty {
                archiveEmptyState(message: "No archived submissions.", icon: "tray")
            } else {
                List {
                    Section("\(archivedSubmissions.count) archived") {
                        ForEach(Array(archivedSubmissions.prefix(pagination.displayLimit))) { sub in
                            SubmittedFormRow(submission: sub)
                                .swipeActions(edge: .leading) {
                                    Button {
                                        restore(submission: sub)
                                    } label: {
                                        Label("Restore", systemImage: "arrow.uturn.backward")
                                    }
                                    .tint(.green)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        delete(submission: sub)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                        LoadMoreFooter(
                            showing: min(pagination.displayLimit, archivedSubmissions.count),
                            total:   archivedSubmissions.count
                        ) { pagination.loadMore() }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private var archivedTemplatesList: some View {
        Group {
            if archivedTemplates.isEmpty {
                archiveEmptyState(message: "No archived templates.", icon: "books.vertical")
            } else {
                List {
                    Section("\(archivedTemplates.count) archived") {
                        ForEach(archivedTemplates) { template in
                            LibraryTemplateRow(template: template)
                                .swipeActions(edge: .leading) {
                                    Button {
                                        restoreTemplate(template)
                                    } label: {
                                        Label("Restore", systemImage: "arrow.uturn.backward")
                                    }
                                    .tint(.green)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        deleteTemplate(template)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private func archiveEmptyState(message: String, icon: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 48)).foregroundColor(.secondary)
            Text(message).font(.headline)
            Text("Items you archive will appear here.\nSwipe left on any form to archive it.")
                .font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
    }

    // Submissions
    private func restore(submission: FormSubmission) {
        if let idx = store.formSubmissions.firstIndex(where: { $0.id == submission.id }) {
            var updated = store.formSubmissions[idx]
            updated.isArchived = false
            updated.syncStatus = .pending
            store.upsertFormSubmission(updated)
        }
    }
    private func delete(submission: FormSubmission) {
        store.deleteFormSubmission(submission)
    }

    // Templates
    private func restoreTemplate(_ t: FormTemplate) {
        if let idx = store.formTemplates.firstIndex(where: { $0.id == t.id }) {
            var updated = store.formTemplates[idx]
            updated.isArchived = false
            updated.syncStatus = .pending
            store.upsertFormTemplate(updated)
        }
    }
    private func deleteTemplate(_ t: FormTemplate) {
        store.deleteFormTemplate(t)
    }
}
