import SwiftUI

struct ScheduleView: View {
    var store: AppStore
    @State private var selectedTab = 0
    @State private var showingNewJob = false
    @State private var searchText = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    Text("Dashboard").tag(0); Text("Jobs").tag(1); Text("Calendar").tag(2)
                }
                .pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8).background(Color(.systemGray6))

                switch selectedTab {
                case 0: SchedDashboard(store: store)
                case 1: SchedJobsListView(store: store, searchText: $searchText)
                case 2: SchedCalendarView(store: store)
                default: EmptyView()
                }
            }
            .navigationTitle("Schedule")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { showingNewJob = true } label: { Image(systemName: "plus") } } }
            .sheet(isPresented: $showingNewJob) { NewJobView(store: store) }
        }
    }
}

struct SchedDashboard: View {
    var store: AppStore
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    SchedStatCard("Today's Jobs", "\(store.todayJobs.count)", "calendar", .blue)
                    SchedStatCard("Active", "\(store.activeJobs.count)", "bolt.fill", .orange)
                    SchedStatCard("Delayed", "\(store.delayedJobs.count)", "exclamationmark.triangle.fill", .red)
                    SchedStatCard("Unassigned", "\(store.unassignedJobs.count)", "person.badge.plus", .purple)
                }
                .padding(.horizontal)
                if !store.todayJobs.isEmpty {
                    SchedDashSection(title: "On Site Today", icon: "mappin.circle.fill", color: .blue) {
                        ForEach(store.todayJobs) { job in NavigationLink(destination: JobDetailView(job: job, store: store)) { JobCardMini(job: job) } }
                    }
                }
                if !store.jobsThisWeek().isEmpty {
                    SchedDashSection(title: "Starting This Week", icon: "calendar.badge.clock", color: .orange) {
                        ForEach(store.jobsThisWeek()) { job in NavigationLink(destination: JobDetailView(job: job, store: store)) { JobCardMini(job: job) } }
                    }
                }
                if !store.delayedJobs.isEmpty {
                    SchedDashSection(title: "Delayed Jobs", icon: "exclamationmark.triangle.fill", color: .red) {
                        ForEach(store.delayedJobs) { job in NavigationLink(destination: JobDetailView(job: job, store: store)) { JobCardMini(job: job) } }
                    }
                }
                if !store.unassignedJobs.isEmpty {
                    SchedDashSection(title: "Awaiting Crew Assignment", icon: "person.badge.plus", color: .purple) {
                        ForEach(store.unassignedJobs) { job in NavigationLink(destination: JobDetailView(job: job, store: store)) { JobCardMini(job: job) } }
                    }
                }
                Spacer(minLength: 20)
            }
            .padding(.top)
        }
        .background(Color(.systemGray6))
    }
}

struct SchedDashSection<Content: View>: View {
    let title: String; let icon: String; let color: Color; let content: () -> Content
    init(title: String, icon: String, color: Color, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.icon = icon; self.color = color; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Image(systemName: icon).foregroundColor(color); Text(title).font(.headline) }.padding(.horizontal)
            VStack(spacing: 8) { content() }.padding(.horizontal)
        }
    }
}

struct SchedStatCard: View {
    let title: String; let value: String; let icon: String; let color: Color
    init(_ title: String, _ value: String, _ icon: String, _ color: Color) { self.title = title; self.value = value; self.icon = icon; self.color = color }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Image(systemName: icon).foregroundColor(color); Spacer() }
            Text(value).font(.largeTitle).fontWeight(.bold)
            Text(title).font(.caption).foregroundColor(.secondary)
        }
        .padding().background(Color(.systemBackground)).cornerRadius(12).shadow(color: .black.opacity(0.05), radius: 4)
    }
}

struct JobCardMini: View {
    let job: ScheduleJob
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4).fill(job.status.color).frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                HStack { Text(job.jobNumber).font(.caption2).foregroundColor(.secondary); Spacer(); JobPriorityDot(priority: job.priority) }
                Text(job.title).font(.subheadline).fontWeight(.semibold)
                Text(job.clientName).font(.caption).foregroundColor(.secondary)
                HStack {
                    Image(systemName: "mappin").font(.caption2).foregroundColor(.secondary)
                    Text(job.siteAddress).font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    Text(job.tentativeStartDate, style: .date).font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
            JobStatusBadge(status: job.status)
        }
        .padding().background(Color(.systemBackground)).cornerRadius(10).shadow(color: .black.opacity(0.04), radius: 3)
    }
}

struct JobStatusBadge: View {
    let status: JobStatus
    var body: some View {
        Text(status.rawValue).font(.caption2).fontWeight(.semibold)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(status.color.opacity(0.15)).foregroundColor(status.color).cornerRadius(8)
    }
}

struct JobPriorityDot: View {
    let priority: JobPriority
    var body: some View { Circle().fill(priority.color).frame(width: 8, height: 8) }
}

struct SchedJobsListView: View {
    var store: AppStore
    @Binding var searchText: String
    @State private var filterStatus: JobStatus? = nil

    var filtered: [ScheduleJob] {
        var r = store.scheduleJobs
        if !searchText.isEmpty { r = r.filter { $0.title.localizedCaseInsensitiveContains(searchText) || $0.clientName.localizedCaseInsensitiveContains(searchText) || $0.jobNumber.localizedCaseInsensitiveContains(searchText) } }
        if let s = filterStatus { r = r.filter { $0.status == s } }
        return r.sorted { $0.tentativeStartDate < $1.tentativeStartDate }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    SchedChip("All", filterStatus == nil) { filterStatus = nil }
                    ForEach([JobStatus.inProgress, .scheduled, .confirmed, .delayed, .completed], id: \.self) { s in
                        SchedChip(s.rawValue, filterStatus == s) { filterStatus = filterStatus == s ? nil : s }
                    }
                }
                .padding(.horizontal).padding(.vertical, 6)
            }
            .background(Color(.systemGray6))
            if filtered.isEmpty {
                Spacer(); Text("No jobs found").foregroundColor(.secondary); Spacer()
            } else {
                List {
                    ForEach(filtered) { job in
                        NavigationLink(destination: JobDetailView(job: job, store: store)) {
                            JobCardMini(job: job).listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        }
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                    .onDelete { idx in idx.forEach { store.deleteJob(filtered[$0]) } }
                }
                .listStyle(.plain).searchable(text: $searchText, prompt: "Search jobs")
            }
        }
    }
}

struct SchedCalendarView: View {
    var store: AppStore
    @State private var selectedDate = Date()
    @State private var viewMode = 0
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $viewMode) { Text("Week").tag(0); Text("Month").tag(1) }
                .pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
            if viewMode == 0 { SchedWeekView(store: store, selectedDate: $selectedDate) }
            else { SchedMonthView(store: store, selectedDate: $selectedDate) }
        }
    }
}

struct SchedWeekView: View {
    var store: AppStore
    @Binding var selectedDate: Date

    var weekDays: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: selectedDate)
        let weekday = cal.component(.weekday, from: today)
        let start = cal.date(byAdding: .day, value: -(weekday - 2), to: today) ?? today
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    var weekRangeText: String {
        guard let first = weekDays.first, let last = weekDays.last else { return "" }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return "\(f.string(from: first)) – \(f.string(from: last))"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { selectedDate = Calendar.current.date(byAdding: .weekOfYear, value: -1, to: selectedDate) ?? selectedDate } label: { Image(systemName: "chevron.left").padding() }
                Spacer(); Text(weekRangeText).font(.subheadline).fontWeight(.semibold); Spacer()
                Button { selectedDate = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: selectedDate) ?? selectedDate } label: { Image(systemName: "chevron.right").padding() }
            }
            .background(Color(.systemGray6))
            HStack(spacing: 0) {
                ForEach(weekDays, id: \.self) { day in
                    VStack(spacing: 4) {
                        Text(day, format: .dateTime.weekday(.abbreviated)).font(.caption2).foregroundColor(.secondary)
                        ZStack {
                            Circle().fill(Calendar.current.isDateInToday(day) ? Color.blue : Color.clear).frame(width: 28, height: 28)
                            Text(day, format: .dateTime.day()).font(.subheadline)
                                .fontWeight(Calendar.current.isDateInToday(day) ? .bold : .regular)
                                .foregroundColor(Calendar.current.isDateInToday(day) ? .white : .primary)
                        }
                        .onTapGesture { selectedDate = day }
                        Circle().fill(store.jobsFor(date: day).count > 0 ? Color.orange : Color.clear).frame(width: 6, height: 6)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 8).background(Color(.systemBackground))
            Divider()
            let dayJobs = store.jobsFor(date: selectedDate)
            if dayJobs.isEmpty {
                VStack { Spacer(); Image(systemName: "calendar.badge.checkmark").font(.system(size: 40)).foregroundColor(.gray.opacity(0.4)); Text("No jobs scheduled").foregroundColor(.secondary).padding(.top, 8); Spacer() }
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(dayJobs) { job in NavigationLink(destination: JobDetailView(job: job, store: store)) { SchedJobBlock(job: job) } }
                    }.padding()
                }
            }
        }
    }
}

struct SchedMonthView: View {
    var store: AppStore
    @Binding var selectedDate: Date

    var monthDays: [Date?] {
        let cal = Calendar.current
        let components = cal.dateComponents([.year, .month], from: selectedDate)
        guard let firstDay = cal.date(from: components), let range = cal.range(of: .day, in: .month, for: firstDay) else { return [] }
        let firstWeekday = (cal.component(.weekday, from: firstDay) + 5) % 7
        var days: [Date?] = Array(repeating: nil, count: firstWeekday)
        for day in range { days.append(cal.date(byAdding: .day, value: day - 1, to: firstDay)) }
        while days.count % 7 != 0 { days.append(nil) }
        return days
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Button { selectedDate = Calendar.current.date(byAdding: .month, value: -1, to: selectedDate) ?? selectedDate } label: { Image(systemName: "chevron.left").padding() }
                    Spacer(); Text(selectedDate, format: .dateTime.month(.wide).year()).font(.headline); Spacer()
                    Button { selectedDate = Calendar.current.date(byAdding: .month, value: 1, to: selectedDate) ?? selectedDate } label: { Image(systemName: "chevron.right").padding() }
                }
                HStack(spacing: 0) {
                    ForEach(["M","T","W","T","F","S","S"], id: \.self) { Text($0).font(.caption).fontWeight(.semibold).foregroundColor(.secondary).frame(maxWidth: .infinity) }
                }.padding(.bottom, 4)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 4) {
                    ForEach(Array(monthDays.enumerated()), id: \.offset) { _, day in
                        if let day = day {
                            let jobs = store.jobsFor(date: day)
                            VStack(spacing: 2) {
                                ZStack {
                                    Circle().fill(Calendar.current.isDateInToday(day) ? Color.blue : Color.clear).frame(width: 28, height: 28)
                                    Text(day, format: .dateTime.day()).font(.caption)
                                        .fontWeight(Calendar.current.isDateInToday(day) ? .bold : .regular)
                                        .foregroundColor(Calendar.current.isDateInToday(day) ? .white : .primary)
                                }.onTapGesture { selectedDate = day }
                                if !jobs.isEmpty {
                                    HStack(spacing: 2) { ForEach(jobs.prefix(3)) { job in Circle().fill(job.status.color).frame(width: 5, height: 5) } }
                                } else { Spacer().frame(height: 5) }
                            }.frame(height: 44)
                        } else { Color.clear.frame(height: 44) }
                    }
                }.padding(.horizontal)
                Divider().padding(.vertical, 8)
                let dayJobs = store.jobsFor(date: selectedDate)
                if !dayJobs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(selectedDate, format: .dateTime.weekday(.wide).month().day()).font(.headline).padding(.horizontal)
                        ForEach(dayJobs) { job in NavigationLink(destination: JobDetailView(job: job, store: store)) { SchedJobBlock(job: job) }.padding(.horizontal) }
                    }
                }
            }
        }
    }
}

struct SchedJobBlock: View {
    let job: ScheduleJob
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3).fill(job.status.color).frame(width: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).font(.subheadline).fontWeight(.semibold).foregroundColor(.primary)
                Text(job.clientName).font(.caption).foregroundColor(.secondary)
                HStack {
                    Image(systemName: job.serviceType.icon).font(.caption2).foregroundColor(.blue)
                    Text(job.serviceType.rawValue).font(.caption2).foregroundColor(.secondary)
                    if !job.assignedCrew.isEmpty { Text("· \(job.assignedCrew.count) crew").font(.caption2).foregroundColor(.secondary) }
                }
            }
            Spacer()
            JobStatusBadge(status: job.status)
        }
        .padding().background(Color(.systemBackground)).cornerRadius(10).shadow(color: .black.opacity(0.04), radius: 3)
    }
}

struct JobDetailView: View {
    @State var job: ScheduleJob
    var store: AppStore
    @State private var showingEdit = false

    var linkedEstimates: [Estimate] { store.estimates.filter { $0.projectName == job.title || $0.clientName == job.clientName } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(job.jobNumber).font(.caption).foregroundColor(.secondary); Spacer(); JobPriorityDot(priority: job.priority); Text(job.priority.rawValue).font(.caption).foregroundColor(job.priority.color) }
                    Text(job.title).font(.title2).fontWeight(.bold)
                    Text(job.clientName).font(.subheadline).foregroundColor(.secondary)
                    HStack { Image(systemName: "mappin").foregroundColor(.red); Text(job.siteAddress).font(.caption) }
                    HStack { Image(systemName: job.serviceType.icon).foregroundColor(.blue); Text(job.serviceType.rawValue).font(.caption); Spacer(); Text(job.company).font(.caption).foregroundColor(.secondary) }
                }
                .padding().background(Color(.systemGray6)).cornerRadius(12)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Status").font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(JobStatus.allCases, id: \.self) { s in
                                Button { job.status = s; store.updateJob(job) } label: {
                                    Text(s.rawValue).font(.caption).fontWeight(.semibold)
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(job.status == s ? s.color : s.color.opacity(0.1))
                                        .foregroundColor(job.status == s ? .white : s.color).cornerRadius(20)
                                }
                            }
                        }.padding(.horizontal)
                    }
                }

                VStack(spacing: 0) {
                    JobDetailRow("Start Date", job.tentativeStartDate.formatted(date: .abbreviated, time: .omitted))
                    JobDetailRow("End Date", job.expectedEndDate.formatted(date: .abbreviated, time: .omitted))
                    JobDetailRow("Duration", "\(job.durationDays) days")
                    JobDetailRow("Supervisor", job.supervisor.isEmpty ? "Unassigned" : job.supervisor)
                    JobDetailRow("Crew Size", "\(job.crewSize) workers")
                    JobDetailRow("Sq Footage", "\(Int(job.estimatedSqFt)) sq ft")
                    if job.budgetValue > 0 { JobDetailRow("Budget", "$\(Int(job.budgetValue).formatted())") }
                }
                .background(Color(.systemBackground)).cornerRadius(12).shadow(color: .black.opacity(0.04), radius: 3)

                if !job.assignedCrew.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Assigned Crew").font(.headline)
                        ForEach(job.assignedCrew, id: \.self) { member in
                            HStack { Image(systemName: "person.circle.fill").foregroundColor(.blue); Text(member).font(.subheadline) }.padding(.vertical, 4)
                        }
                    }
                    .padding().background(Color(.systemBackground)).cornerRadius(12).shadow(color: .black.opacity(0.04), radius: 3)
                } else {
                    HStack { Image(systemName: "person.badge.plus").foregroundColor(.orange); Text("No crew assigned").foregroundColor(.orange) }
                        .padding().background(Color.orange.opacity(0.08)).cornerRadius(12)
                }

                if !job.scopeDescription.isEmpty {
                    VStack(alignment: .leading, spacing: 6) { Text("Scope").font(.headline); Text(job.scopeDescription).font(.subheadline).foregroundColor(.secondary) }
                        .padding().background(Color(.systemBackground)).cornerRadius(12).shadow(color: .black.opacity(0.04), radius: 3)
                }

                if job.status == .delayed {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red); Text("Delay Information").font(.headline).foregroundColor(.red) }
                        if let reason = job.delayReason { Text("Reason: \(reason.rawValue)").font(.subheadline) }
                        if !job.delayNotes.isEmpty { Text(job.delayNotes).font(.subheadline).foregroundColor(.secondary) }
                    }
                    .padding().background(Color.red.opacity(0.06)).cornerRadius(12)
                }

                if !linkedEstimates.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Linked Estimates").font(.headline)
                        ForEach(linkedEstimates) { est in
                            HStack {
                                Text(est.estimateNumber).font(.caption).foregroundColor(.secondary)
                                Text(est.projectName).font(.subheadline)
                                Spacer()
                                Text(est.calculationResult.totalSell.currency).fontWeight(.semibold).foregroundColor(.blue)
                            }
                        }
                    }
                    .padding().background(Color(.systemBackground)).cornerRadius(12).shadow(color: .black.opacity(0.04), radius: 3)
                }

                HStack(spacing: 12) {
                    Button { store.duplicateJob(job) } label: { Label("Duplicate", systemImage: "doc.on.doc").frame(maxWidth: .infinity).padding().background(Color(.systemGray6)).cornerRadius(10) }
                    Button { showingEdit = true } label: { Label("Edit", systemImage: "pencil").frame(maxWidth: .infinity).padding().background(Color.blue.opacity(0.1)).foregroundColor(.blue).cornerRadius(10) }
                }
            }.padding()
        }
        .navigationTitle(job.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingEdit) { EditJobView(job: $job, store: store) }
    }
}

struct JobDetailRow: View {
    let label: String; let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(label).font(.subheadline).foregroundColor(.secondary); Spacer(); Text(value).font(.subheadline).fontWeight(.medium) }
                .padding(.horizontal).padding(.vertical, 8)
            Divider().padding(.horizontal)
        }
    }
}

struct NewJobView: View {
    var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var job = ScheduleJob()
    var body: some View {
        NavigationView {
            JobFormContent(job: $job, store: store).navigationTitle("New Job").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .navigationBarTrailing) { Button("Save") { store.addJob(job); dismiss() }.fontWeight(.semibold).disabled(job.title.isEmpty || job.clientName.isEmpty) }
                }
        }
    }
}

struct EditJobView: View {
    @Binding var job: ScheduleJob
    var store: AppStore
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationView {
            JobFormContent(job: $job, store: store).navigationTitle("Edit Job").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .navigationBarTrailing) { Button("Save") { store.updateJob(job); dismiss() }.fontWeight(.semibold) }
                }
        }
    }
}

struct JobFormContent: View {
    @Binding var job: ScheduleJob
    var store: AppStore

    var body: some View {
        Form {
            Section("Project Info") {
                Picker("Link to Project", selection: $job.title) {
                    Text("Custom / No Link").tag(job.title.isEmpty ? "" : job.title)
                    ForEach(store.projectNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .onChange(of: job.title) { _, newTitle in
                    if let proj = store.projects.first(where: { $0.name == newTitle }) {
                        job.clientName = proj.client
                        job.siteAddress = proj.location
                    }
                }
                TextField("Job Title", text: $job.title)
                TextField("Client Name", text: $job.clientName)
                TextField("Site Address", text: $job.siteAddress)
                TextField("Region", text: $job.region)
                Picker("Company", selection: $job.company) {
                    Text("Blair Ventures").tag("Blair Ventures")
                    Text("Integral Containment Systems").tag("Integral Containment Systems")
                }
            }
            Section("Service & Priority") {
                Picker("Service Type", selection: $job.serviceType) { ForEach(ServiceType.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Picker("Priority", selection: $job.priority) { ForEach(JobPriority.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Picker("Status", selection: $job.status) { ForEach(JobStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            }
            Section("Schedule") {
                DatePicker("Start Date", selection: $job.tentativeStartDate, displayedComponents: .date)
                DatePicker("End Date", selection: $job.expectedEndDate, displayedComponents: .date)
                Picker("Shift Type", selection: $job.shiftType) { ForEach(ShiftType.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                TextField("Working Hours", text: $job.workingHours)
            }
            Section("Crew") {
                TextField("Supervisor", text: $job.supervisor)
                Stepper("Crew Size: \(job.crewSize)", value: $job.crewSize, in: 1...30)
                Picker("Add Crew Member", selection: Binding<String>(
                    get: { "" },
                    set: { if !$0.isEmpty && !job.assignedCrew.contains($0) { job.assignedCrew.append($0) } }
                )) {
                    Text("Select crew member").tag("")
                    ForEach(store.crewNames, id: \.self) { Text($0).tag($0) }
                }
                ForEach(job.assignedCrew, id: \.self) { member in
                    HStack {
                        Image(systemName: "person.circle").foregroundColor(.blue)
                        Text(member)
                    }
                }
                .onDelete { job.assignedCrew.remove(atOffsets: $0) }                    .onDelete { job.assignedCrew.remove(atOffsets: $0) }
            }
            Section("Scope") {
                TextField("Description", text: $job.scopeDescription, axis: .vertical).lineLimit(4)
                TextField("Estimated Sq Ft", value: $job.estimatedSqFt, format: .number).keyboardType(.numberPad)
                Stepper("Levels: \(job.numberOfLevels)", value: $job.numberOfLevels, in: 1...20)
                Toggle("Scaffold Required", isOn: $job.scaffoldRequired)
                Toggle("Containment Only", isOn: $job.containmentOnly)
            }
            if job.status == .delayed {
                Section("Delay") {
                    Picker("Delay Reason", selection: Binding(
                        get: { job.delayReason ?? .other },
                        set: { job.delayReason = $0 }
                    )) {
                        ForEach(DelayReason.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    TextField("Delay Notes", text: $job.delayNotes, axis: .vertical).lineLimit(3)
                }
            }
            Section("Billing") {
                TextField("Quote Number", text: $job.quoteNumber)
                TextField("PO Number", text: $job.poNumber)
                TextField("Budget Value ($)", value: $job.budgetValue, format: .number).keyboardType(.decimalPad)
            }
            Section("Safety & Access") {
                TextField("Hazard Notes", text: $job.hazardNotes, axis: .vertical).lineLimit(3)
                TextField("Access Instructions", text: $job.accessInstructions, axis: .vertical).lineLimit(3)
                Toggle("Orientation Required", isOn: $job.orientationRequired)
            }
            Section("Notes") {
                TextField("General Notes", text: $job.generalNotes, axis: .vertical).lineLimit(4)
            }
        }
    }
}

struct SchedChip: View {
    let label: String; let selected: Bool; let action: () -> Void
    init(_ label: String, _ selected: Bool, _ action: @escaping () -> Void) { self.label = label; self.selected = selected; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(label).font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Color.blue : Color(.systemGray5))
                .foregroundColor(selected ? .white : .primary).cornerRadius(16)
        }
    }
}
