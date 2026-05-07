// RFIViews.swift
// Aski IQ – Request for Information UI
// List → Detail → Create/Edit flow with response workflow.

import SwiftUI

// MARK: - Global / Per-Project List

struct RFIListView: View {
    @EnvironmentObject var store: AppStore
    var projectID: UUID? = nil

    @State private var showCreate = false
    @State private var filterStatus: RFIStatus? = nil

    private var items: [RFI] {
        var list = projectID != nil
            ? store.rfis(for: projectID!)
            : store.rfis
        if let s = filterStatus { list = list.filter { $0.status == s } }
        return list.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        RFIListBody(items: items, filterStatus: $filterStatus, projectID: projectID)
            .navigationTitle(projectID != nil ? "RFIs" : "All RFIs")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refreshAll() }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showCreate = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showCreate) {
                RFICreateEditView(projectID: projectID ?? store.projects.first?.id ?? UUID())
            }
    }
}

private struct RFIListBody: View {
    let items: [RFI]
    @Binding var filterStatus: RFIStatus?
    let projectID: UUID?

    var body: some View {
        List {
            RFIListSummarySection(items: items)
            RFIListFilterSection(filterStatus: $filterStatus)
            RFIListItemsSection(items: items, projectID: projectID)
        }
    }
}

private struct RFIListSummarySection: View {
    let items: [RFI]
    var body: some View {
        let open     = items.filter { $0.status.isOpen }
        let overdue  = items.filter { $0.isOverdue }
        let answered = items.filter { $0.status == .answered || $0.status == .closed }
        Section {
            HStack(spacing: 0) {
                RFISummaryCell(label: "Open",     value: "\(open.count)",     color: open.isEmpty ? .secondary : .orange)
                Divider().frame(height: 36)
                RFISummaryCell(label: "Overdue",  value: "\(overdue.count)",  color: overdue.isEmpty ? .secondary : .red)
                Divider().frame(height: 36)
                RFISummaryCell(label: "Answered", value: "\(answered.count)", color: .green)
            }
        }
    }
}

private struct RFISummaryCell: View {
    let label: String; let value: String; let color: Color
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).foregroundColor(color)
            Text(label).font(.caption).foregroundColor(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

private struct RFIListFilterSection: View {
    @Binding var filterStatus: RFIStatus?
    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(label: "All", isSelected: filterStatus == nil) { filterStatus = nil }
                    ForEach(RFIStatus.allCases, id: \.self) { s in
                        FilterChip(label: s.displayName, isSelected: filterStatus == s) {
                            filterStatus = filterStatus == s ? nil : s
                        }
                    }
                }
                .padding(.horizontal, 4).padding(.vertical, 4)
            }
        }
    }
}

private struct RFIListItemsSection: View {
    let items: [RFI]
    let projectID: UUID?
    var body: some View {
        if items.isEmpty {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "questionmark.bubble").font(.largeTitle).foregroundColor(.secondary)
                    Text("No RFIs found.").font(.subheadline).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
            }
        } else {
            Section {
                ForEach(items) { rfi in
                    NavigationLink(destination: RFIDetailView(rfi: rfi)) {
                        RFIRow(rfi: rfi, showProject: projectID == nil)
                    }
                }
            }
        }
    }
}

// MARK: - Row

struct RFIRow: View {
    @EnvironmentObject var store: AppStore
    let rfi: RFI
    var showProject: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                RFIStatusBadge(status: rfi.status)
                RFIPriorityBadge(priority: rfi.priority)
                Spacer()
                if rfi.isOverdue {
                    Label("Overdue", systemImage: "clock.badge.exclamationmark")
                        .font(.caption2).bold().foregroundColor(.red)
                }
            }
            Text(rfi.number).font(.caption2).foregroundColor(.secondary)
            Text(rfi.title).font(.subheadline).bold()
            if showProject, let proj = store.project(id: rfi.projectID) {
                Text(proj.name).font(.caption).foregroundColor(.secondary)
            }
            HStack(spacing: 12) {
                Label(rfi.category.displayName, systemImage: rfi.category.icon)
                    .font(.caption).foregroundColor(.secondary)
                if let deadline = rfi.requiredByDate, rfi.status.needsAnswer {
                    Spacer()
                    Label("Due \(deadline.formatted(date: .abbreviated, time: .omitted))",
                          systemImage: "calendar")
                        .font(.caption)
                        .foregroundColor(rfi.isOverdue ? .red : .secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail View

struct RFIDetailView: View {
    @EnvironmentObject var store: AppStore
    @State private var rfi: RFI
    @State private var showEdit = false
    @State private var showAnswer = false
    @State private var showDeleteConfirm = false
    @State private var showCreateCO = false
    @Environment(\.dismiss) var dismiss

    init(rfi: RFI) { _rfi = State(initialValue: rfi) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                RFIDetailHeaderCard(rfi: rfi)
                RFIDetailQuestionCard(rfi: rfi)
                if let answer = rfi.answer, !answer.isEmpty {
                    RFIDetailAnswerCard(rfi: rfi)
                }
                RFIDetailImpactCard(rfi: rfi, showCreateCO: $showCreateCO)
                RFIDetailStatusActions(rfi: $rfi, showAnswer: $showAnswer)
                if let notes = rfi.internalNotes, !notes.isEmpty {
                    RFIDetailNotesCard(notes: notes)
                }
                Spacer(minLength: 32)
            }
            .padding(.top)
        }
        .navigationTitle(rfi.number)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { showEdit = true } label: { Label("Edit", systemImage: "pencil") }
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showEdit, onDismiss: { refreshFromStore() }) {
            RFICreateEditView(existing: rfi, projectID: rfi.projectID)
        }
        .sheet(isPresented: $showAnswer) {
            RFIAnswerSheet(rfi: $rfi)
        }
        .sheet(isPresented: $showCreateCO) {
            ChangeOrderCreateEditView(projectID: rfi.projectID)
        }
        .confirmationDialog("Delete this RFI?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.deleteRFI(rfi); dismiss() }
            Button("Cancel", role: .cancel) {}
        }
        .onReceive(store.$rfis) { _ in refreshFromStore() }
    }

    private func refreshFromStore() {
        if let updated = store.rfis.first(where: { $0.id == rfi.id }) { rfi = updated }
    }
}

private struct RFIDetailHeaderCard: View {
    let rfi: RFI
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RFIStatusBadge(status: rfi.status)
                RFIPriorityBadge(priority: rfi.priority)
                Spacer()
                if rfi.isOverdue {
                    Label("Overdue", systemImage: "clock.badge.exclamationmark")
                        .font(.caption).bold().foregroundColor(.red)
                }
            }
            Text(rfi.title).font(.title3).bold()
            HStack(spacing: 16) {
                Label(rfi.category.displayName, systemImage: rfi.category.icon)
                    .font(.subheadline).foregroundColor(.secondary)
                if let ref = rfi.reference, !ref.isEmpty {
                    Label(ref, systemImage: "doc.text").font(.subheadline).foregroundColor(.secondary)
                }
            }
            if let deadline = rfi.requiredByDate {
                HStack {
                    Label("Required by", systemImage: "calendar.badge.clock")
                        .font(.subheadline).foregroundColor(.secondary)
                    Spacer()
                    Text(deadline.formatted(date: .abbreviated, time: .omitted))
                        .font(.subheadline)
                        .foregroundColor(rfi.isOverdue ? .red : .primary)
                        .bold(rfi.isOverdue)
                }
            }
            if let name = rfi.submittedByName, !name.isEmpty {
                HStack {
                    Label("Submitted by", systemImage: "person").font(.subheadline).foregroundColor(.secondary)
                    Spacer()
                    Text(name).font(.subheadline)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .padding(.horizontal)
    }
}

private struct RFIDetailQuestionCard: View {
    let rfi: RFI
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Question").font(.headline).padding(.horizontal)
            VStack(alignment: .leading, spacing: 6) {
                Text(rfi.question.isEmpty ? "No question text entered." : rfi.question)
                    .font(.body)
                    .foregroundColor(rfi.question.isEmpty ? .secondary : .primary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }
}

private struct RFIDetailAnswerCard: View {
    let rfi: RFI
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Response").font(.headline).padding(.horizontal)
            VStack(alignment: .leading, spacing: 8) {
                if let answer = rfi.answer {
                    Text(answer).font(.body)
                }
                HStack {
                    if let name = rfi.answeredByName, !name.isEmpty {
                        Text("— \(name)").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    if let date = rfi.answeredDate {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .padding()
            .background(Color.green.opacity(0.06))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }
}

private struct RFIDetailImpactCard: View {
    let rfi: RFI
    @Binding var showCreateCO: Bool

    var body: some View {
        if rfi.hasCostImpact || rfi.hasScheduleImpact {
            VStack(alignment: .leading, spacing: 8) {
                Text("Impact Flags").font(.headline).padding(.horizontal)
                VStack(spacing: 8) {
                    if rfi.hasCostImpact {
                        HStack {
                            Label("Cost Impact", systemImage: "dollarsign.circle.fill")
                                .foregroundColor(.orange)
                            Spacer()
                            if rfi.linkedChangeOrderID == nil {
                                Button("Create CO") { showCreateCO = true }
                                    .font(.caption).bold()
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Color.orange.opacity(0.12))
                                    .foregroundColor(.orange).cornerRadius(8)
                            } else {
                                Label("CO linked", systemImage: "link").font(.caption).foregroundColor(.green)
                            }
                        }
                    }
                    if rfi.hasScheduleImpact {
                        HStack {
                            Label("Schedule Impact", systemImage: "calendar.badge.exclamationmark")
                                .foregroundColor(.red)
                            Spacer()
                        }
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)
            }
        }
    }
}

private struct RFIDetailStatusActions: View {
    @EnvironmentObject var store: AppStore
    @Binding var rfi: RFI
    @Binding var showAnswer: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Actions").font(.headline).padding(.horizontal)
            VStack(spacing: 8) {
                if rfi.status == .draft {
                    RFIActionButton(label: "Submit RFI", color: .blue, icon: "paperplane.fill") {
                        var u = rfi; u.status = .submitted; u.submittedDate = Date()
                        store.upsertRFI(u)
                    }
                }
                if rfi.status == .submitted {
                    RFIActionButton(label: "Mark Under Review", color: .orange, icon: "eye.circle") {
                        var u = rfi; u.status = .underReview; store.upsertRFI(u)
                    }
                }
                if rfi.status == .submitted || rfi.status == .underReview {
                    RFIActionButton(label: "Enter Response", color: .purple, icon: "text.bubble.fill") {
                        showAnswer = true
                    }
                }
                if rfi.status == .answered {
                    RFIActionButton(label: "Close RFI", color: .green, icon: "checkmark.circle.fill") {
                        var u = rfi; u.status = .closed; u.closedDate = Date()
                        store.upsertRFI(u)
                    }
                }
                if rfi.status != .voided && rfi.status != .closed {
                    RFIActionButton(label: "Void", color: .secondary, icon: "slash.circle") {
                        var u = rfi; u.status = .voided; store.upsertRFI(u)
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

private struct RFIDetailNotesCard: View {
    let notes: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Internal Notes").font(.headline).padding(.horizontal)
            Text(notes)
                .font(.subheadline).foregroundColor(.secondary)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)
        }
    }
}

private struct RFIActionButton: View {
    let label: String; let color: Color; let icon: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.subheadline).bold()
                .frame(maxWidth: .infinity).padding()
                .background(color.opacity(0.12)).foregroundColor(color)
                .cornerRadius(12)
        }
    }
}

// MARK: - Answer Sheet

private struct RFIAnswerSheet: View {
    @EnvironmentObject var store: AppStore
    @Binding var rfi: RFI
    @Environment(\.dismiss) var dismiss

    @State private var answer: String = ""
    @State private var answeredBy: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Response") {
                    TextField("Enter the response…", text: $answer, axis: .vertical)
                        .lineLimit(4...12)
                }
                Section("Responded by") {
                    TextField("Engineer / Owner name", text: $answeredBy)
                }
            }
            .navigationTitle("Enter Response")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        var updated = rfi
                        updated.answer        = answer
                        updated.answeredByName = answeredBy.isEmpty ? nil : answeredBy
                        updated.answeredDate  = Date()
                        updated.status        = .answered
                        store.upsertRFI(updated)
                        dismiss()
                    }
                    .bold().disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear {
            answer      = rfi.answer ?? ""
            answeredBy  = rfi.answeredByName ?? ""
        }
    }
}

// MARK: - Create / Edit Sheet

struct RFICreateEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    var existing: RFI? = nil
    var projectID: UUID

    @State private var title        = ""
    @State private var category: RFICategory = .other
    @State private var priority: RFIPriority = .normal
    @State private var question     = ""
    @State private var reference    = ""
    @State private var submittedBy  = ""
    @State private var requiredByDate: Date = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var hasDeadline  = true
    @State private var hasCostImpact = false
    @State private var hasScheduleImpact = false
    @State private var internalNotes = ""

    private var isEditing: Bool { existing != nil }

    var body: some View {
        NavigationStack {
            RFICreateForm(
                title: $title,
                category: $category,
                priority: $priority,
                question: $question,
                reference: $reference,
                submittedBy: $submittedBy,
                requiredByDate: $requiredByDate,
                hasDeadline: $hasDeadline,
                hasCostImpact: $hasCostImpact,
                hasScheduleImpact: $hasScheduleImpact,
                internalNotes: $internalNotes
            )
            .navigationTitle(isEditing ? "Edit RFI" : "New RFI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }
                        .bold()
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear { populate() }
    }

    private func populate() {
        guard let r = existing else { return }
        title             = r.title
        category          = r.category
        priority          = r.priority
        question          = r.question
        reference         = r.reference ?? ""
        submittedBy       = r.submittedByName ?? ""
        if let d = r.requiredByDate { requiredByDate = d; hasDeadline = true }
        hasCostImpact     = r.hasCostImpact
        hasScheduleImpact = r.hasScheduleImpact
        internalNotes     = r.internalNotes ?? ""
    }

    private func save() {
        var rfi = existing ?? RFI(
            number: store.nextRFINumber(for: projectID),
            title: title,
            projectID: projectID
        )
        rfi.title             = title.trimmingCharacters(in: .whitespaces)
        rfi.category          = category
        rfi.priority          = priority
        rfi.question          = question
        rfi.reference         = reference.isEmpty ? nil : reference
        rfi.submittedByName   = submittedBy.isEmpty
            ? store.currentUser?.fullName
            : submittedBy
        rfi.submittedByID     = store.currentUser?.id
        rfi.requiredByDate    = hasDeadline ? requiredByDate : nil
        rfi.hasCostImpact     = hasCostImpact
        rfi.hasScheduleImpact = hasScheduleImpact
        rfi.internalNotes     = internalNotes.isEmpty ? nil : internalNotes
        store.upsertRFI(rfi)
        dismiss()
    }
}

// Extracted to keep form body under 10 children
private struct RFICreateForm: View {
    @Binding var title: String
    @Binding var category: RFICategory
    @Binding var priority: RFIPriority
    @Binding var question: String
    @Binding var reference: String
    @Binding var submittedBy: String
    @Binding var requiredByDate: Date
    @Binding var hasDeadline: Bool
    @Binding var hasCostImpact: Bool
    @Binding var hasScheduleImpact: Bool
    @Binding var internalNotes: String

    var body: some View {
        Form {
            RFIFormIdentitySection(title: $title, category: $category, priority: $priority)
            RFIFormQuestionSection(question: $question, reference: $reference)
            RFIFormDeadlineSection(requiredByDate: $requiredByDate, hasDeadline: $hasDeadline, submittedBy: $submittedBy)
            RFIFormImpactSection(hasCostImpact: $hasCostImpact, hasScheduleImpact: $hasScheduleImpact)
            RFIFormNotesSection(internalNotes: $internalNotes)
        }
    }
}

private struct RFIFormIdentitySection: View {
    @Binding var title: String
    @Binding var category: RFICategory
    @Binding var priority: RFIPriority
    var body: some View {
        Section("RFI Details") {
            TextField("Title / subject", text: $title)
            Picker("Category", selection: $category) {
                ForEach(RFICategory.allCases, id: \.self) { c in
                    Label(c.displayName, systemImage: c.icon).tag(c)
                }
            }
            Picker("Priority", selection: $priority) {
                ForEach(RFIPriority.allCases, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
        }
    }
}

private struct RFIFormQuestionSection: View {
    @Binding var question: String
    @Binding var reference: String
    var body: some View {
        Section("Question") {
            TextField("Describe the question or clarification needed…",
                      text: $question, axis: .vertical).lineLimit(4...10)
            TextField("Drawing / spec reference (optional)", text: $reference)
        }
    }
}

private struct RFIFormDeadlineSection: View {
    @Binding var requiredByDate: Date
    @Binding var hasDeadline: Bool
    @Binding var submittedBy: String
    var body: some View {
        Section("Deadline & Submission") {
            Toggle("Set Response Deadline", isOn: $hasDeadline)
            if hasDeadline {
                DatePicker("Required by", selection: $requiredByDate, displayedComponents: .date)
            }
            TextField("Submitted by (name)", text: $submittedBy)
        }
    }
}

private struct RFIFormImpactSection: View {
    @Binding var hasCostImpact: Bool
    @Binding var hasScheduleImpact: Bool
    var body: some View {
        Section("Potential Impact") {
            Toggle("May have cost impact", isOn: $hasCostImpact)
            Toggle("May affect schedule", isOn: $hasScheduleImpact)
        }
    }
}

private struct RFIFormNotesSection: View {
    @Binding var internalNotes: String
    var body: some View {
        Section("Internal Notes") {
            TextField("Internal notes (not visible to client)…",
                      text: $internalNotes, axis: .vertical).lineLimit(2...6)
        }
    }
}

// MARK: - Status Badge

struct RFIStatusBadge: View {
    let status: RFIStatus

    private var color: Color {
        switch status {
        case .draft:       return .gray
        case .submitted:   return .blue
        case .underReview: return .orange
        case .answered:    return .purple
        case .closed:      return .green
        case .voided:      return .gray
        }
    }

    var body: some View {
        Label(status.displayName, systemImage: status.icon)
            .font(.caption2).bold()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(6)
    }
}

struct RFIPriorityBadge: View {
    let priority: RFIPriority

    private var color: Color {
        switch priority {
        case .low:    return .secondary
        case .normal: return .blue
        case .high:   return .orange
        case .urgent: return .red
        }
    }

    var body: some View {
        if priority != .normal {
            Label(priority.displayName, systemImage: priority.icon)
                .font(.caption2).bold()
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(color.opacity(0.12))
                .foregroundColor(color)
                .cornerRadius(6)
        }
    }
}

// MARK: - Project RFI Summary (used in ProjectDetailView)

struct ProjectRFISection: View {
    @EnvironmentObject var store: AppStore
    let project: Project

    private var rfiList: [RFI] { store.rfis(for: project.id) }
    private var open: [RFI]    { rfiList.filter { $0.status.isOpen } }

    var body: some View {
        Group {
            Divider().padding(.horizontal)
            HStack {
                SectionHeader(title: "RFIs", count: rfiList.count)
                if !rfiList.isEmpty {
                    NavigationLink("See All", destination: RFIListView(projectID: project.id))
                        .font(.subheadline).padding(.trailing)
                }
            }
            if rfiList.isEmpty {
                EmptyCard(message: "No RFIs on this project.")
            } else {
                VStack(spacing: 0) {
                    ProjectRFIStats(rfiList: rfiList, open: open)
                    Divider()
                    ForEach(rfiList.prefix(3)) { rfi in
                        NavigationLink(destination: RFIDetailView(rfi: rfi)) {
                            RFIRow(rfi: rfi, showProject: false).padding(.horizontal)
                        }
                        if rfi.id != rfiList.prefix(3).last?.id { Divider().padding(.leading) }
                    }
                    if rfiList.count > 3 {
                        Divider()
                        NavigationLink(destination: RFIListView(projectID: project.id)) {
                            Text("See all \(rfiList.count) RFIs")
                                .font(.subheadline).foregroundColor(.blue)
                                .frame(maxWidth: .infinity).padding()
                        }
                    }
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12).padding(.horizontal)
            }
        }
    }
}

private struct ProjectRFIStats: View {
    let rfiList: [RFI]
    let open: [RFI]
    var body: some View {
        let overdue  = rfiList.filter { $0.isOverdue }
        let answered = rfiList.filter { $0.status == .answered || $0.status == .closed }
        HStack(spacing: 0) {
            RFISummaryCell(label: "Open",     value: "\(open.count)",     color: open.isEmpty ? .secondary : .orange)
            Divider().frame(height: 36)
            RFISummaryCell(label: "Overdue",  value: "\(overdue.count)",  color: overdue.isEmpty ? .secondary : .red)
            Divider().frame(height: 36)
            RFISummaryCell(label: "Answered", value: "\(answered.count)", color: .green)
        }
        .padding(.vertical, 8)
    }
}
