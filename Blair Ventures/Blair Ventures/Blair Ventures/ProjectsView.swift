import SwiftUI

struct ProjectsView: View {
    @Bindable var store: AppStore
    @State private var showingAddProject = false

    var body: some View {
        NavigationView {
            List {
                ForEach($store.projects) { $project in
                    NavigationLink(destination: ProjectDetailView(project: $project, store: store)) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(project.name).font(.headline)
                                Spacer()
                                ProjStatusBadge(status: project.status)
                            }
                            Text(project.client).font(.subheadline).foregroundColor(.secondary)
                            Text(project.location).font(.caption).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .onDelete { offsets in
                    offsets.forEach { store.deleteProject(store.projects[$0]) }
                }
            }
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingAddProject = true } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .navigationBarLeading) { EditButton() }
            }
            .sheet(isPresented: $showingAddProject) { AddProjectView(store: store) }
        }
    }
}

struct ProjStatusBadge: View {
    let status: ProjectStatus
    var body: some View {
        Text(status.rawValue).font(.caption).fontWeight(.semibold)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(status.color.opacity(0.2))
            .foregroundColor(status.color).cornerRadius(8)
    }
}

struct ProjectDetailView: View {
    @Binding var project: Project
    var store: AppStore

    var linkedEstimates: [Estimate] {
        store.estimates.filter { $0.projectName == project.name }
    }
    var linkedJobs: [ScheduleJob] {
        store.scheduleJobs.filter { $0.title.contains(project.name) || $0.clientName == project.client }
    }

    var body: some View {
        Form {
            Section("Project Info") {
                LabeledContent("Client", value: project.client)
                LabeledContent("Location", value: project.location)
                LabeledContent("Start Date", value: project.startDate)
                LabeledContent("End Date", value: project.endDate)
            }
            Section("Status") {
                Picker("Status", selection: $project.status) {
                    ForEach(ProjectStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: project.status) { _, _ in store.updateProject(project) }
            }
            Section("Notes") {
                TextField("Notes", text: $project.notes, axis: .vertical).lineLimit(4)
            }
            if !linkedEstimates.isEmpty {
                Section("Linked Estimates (\(linkedEstimates.count))") {
                    ForEach(linkedEstimates) { est in
                        HStack {
                            Text(est.estimateNumber).font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Text(est.calculationResult.totalSell.currency).fontWeight(.semibold).foregroundColor(.blue)
                        }
                    }
                }
            }
            if !linkedJobs.isEmpty {
                Section("Linked Jobs (\(linkedJobs.count))") {
                    ForEach(linkedJobs) { job in
                        HStack {
                            Text(job.title).font(.subheadline)
                            Spacer()
                            Text(job.status.rawValue).font(.caption2).fontWeight(.semibold)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(job.status.color.opacity(0.15))
                                .foregroundColor(job.status.color).cornerRadius(8)
                        }
                    }
                }
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AddProjectView: View {
    var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var client = ""
    @State private var location = ""
    @State private var status = ProjectStatus.pending
    @State private var startDate = ""
    @State private var endDate = ""
    @State private var notes = ""

    var body: some View {
        NavigationView {
            Form {
                Section("Project Info") {
                    TextField("Project Name", text: $name)
                    TextField("Client", text: $client)
                    TextField("Location", text: $location)
                }
                Section("Dates") {
                    TextField("Start Date (YYYY-MM-DD)", text: $startDate)
                    TextField("End Date (YYYY-MM-DD)", text: $endDate)
                }
                Section("Status") {
                    Picker("Status", selection: $status) {
                        ForEach(ProjectStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(4)
                }
            }
            .navigationTitle("New Project")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        store.addProject(Project(name: name, client: client, location: location, status: status, startDate: startDate, endDate: endDate, notes: notes))
                        dismiss()
                    }
                    .disabled(name.isEmpty || client.isEmpty)
                }
            }
        }
    }
}
