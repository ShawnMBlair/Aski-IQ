import SwiftUI
import CoreLocation

struct CrewMember: Identifiable {
    let id = UUID()
    var name: String
    var role: String
    var phone: String
    var company: String
    var checkedIn: Bool = false
    var currentProject: String = ""
    var workLogs: [WorkLog] = []
}

struct WorkLog: Identifiable {
    let id = UUID()
    var date: Date
    var project: String
    var location: String
    var timeIn: Date
    var timeOut: Date?
    var notes: String = ""
    var editHistory: [EditRecord] = []
    var hoursWorked: Double {
        guard let out = timeOut else { return Date().timeIntervalSince(timeIn) / 3600 }
        return out.timeIntervalSince(timeIn) / 3600
    }
    var hoursDisplay: String {
        timeOut == nil ? "In Progress" : String(format: "%.2f hrs", hoursWorked)
    }
}

struct EditRecord: Identifiable {
    let id = UUID()
    let timestamp: Date
    let note: String
}

@Observable
class LocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var locationString = ""
    override init() {
        super.init()
        manager.delegate = self
        manager.requestWhenInUseAuthorization()
    }
    func requestLocation() { manager.requestLocation() }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.first else { return }
        let geocoder = CLGeocoder()
        geocoder.reverseGeocodeLocation(loc) { [weak self] placemarks, _ in
            if let place = placemarks?.first {
                DispatchQueue.main.async {
                    self?.locationString = "\(place.locality ?? ""), \(place.administrativeArea ?? "")"
                }
            }
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async { self.locationString = "Location unavailable" }
    }
}

struct CrewView: View {
    var store: AppStore
    @State private var showingAddCrew = false
    @State private var searchText = ""

    var crew: [CrewMember] { store.crewMembers }
    var projects: [String] { store.activeProjectNames + ["Office", "Unassigned"] }
    var checkedInCount: Int { crew.filter { $0.checkedIn }.count }

    var filteredCrew: [CrewMember] {
        if searchText.isEmpty { return crew }
        return crew.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.role.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("\(checkedInCount) of \(crew.count) Checked In").font(.headline)
                        Text("Today").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "person.fill.checkmark").font(.title2).foregroundColor(.green)
                }
                .padding().background(Color(.systemGray6))

                List {
                    ForEach(filteredCrew) { member in
                        NavigationLink(destination: CrewDetailView(member: member, store: store, projects: projects)) {
                            HStack(spacing: 12) {
                                Circle().fill(member.checkedIn ? Color.green : Color.gray.opacity(0.3)).frame(width: 12, height: 12)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(member.name).font(.headline)
                                    HStack {
                                        Text(member.role).font(.caption).foregroundColor(.secondary)
                                        Text("·").foregroundColor(.secondary)
                                        Text(member.company).font(.caption).foregroundColor(.secondary)
                                    }
                                    if member.checkedIn && !member.currentProject.isEmpty {
                                        Text(member.currentProject).font(.caption2).foregroundColor(.blue)
                                    }
                                }
                                Spacer()
                                Text(member.checkedIn ? "In" : "Out").font(.caption).fontWeight(.semibold)
                                    .foregroundColor(member.checkedIn ? .green : .secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .onDelete { store.deleteCrewMember(at: $0) }
                }
                .searchable(text: $searchText, prompt: "Search crew")
            }
            .navigationTitle("Crew")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingAddCrew = true } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .navigationBarLeading) { EditButton() }
            }
            .sheet(isPresented: $showingAddCrew) { AddCrewView(store: store) }
        }
    }
}

struct CrewDetailView: View {
    var member: CrewMember
    var store: AppStore
    let projects: [String]
    @State private var selectedTab = 0
    @State private var showingEditInfo = false
    @State private var showingAddLog = false
    @State private var showingCheckInSheet = false

    var memberBinding: Binding<CrewMember> {
        Binding(
            get: { store.crewMembers.first(where: { $0.id == member.id }) ?? member },
            set: { store.updateCrewMember($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("Overview").tag(0)
                Text("Hours Log").tag(1)
                Text("Timesheet").tag(2)
            }
            .pickerStyle(.segmented).padding()

            let m = memberBinding.wrappedValue
            if selectedTab == 0 { CrewOverview(member: m, store: store, showCheckIn: $showingCheckInSheet) }
            else if selectedTab == 1 { CrewHoursLog(member: m, store: store) }
            else { CrewTimesheet(member: m) }
        }
        .navigationTitle(member.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { Button("Edit") { showingEditInfo = true } }
        }
        .sheet(isPresented: $showingEditInfo) { EditCrewInfoView(member: memberBinding, store: store) }
        .sheet(isPresented: $showingCheckInSheet) { CheckInSheet(member: memberBinding, projects: projects) }
    }
}

struct CrewOverview: View {
    var member: CrewMember
    var store: AppStore
    @Binding var showCheckIn: Bool

    var activeLog: WorkLog? { member.workLogs.first { $0.timeOut == nil } }
    var todayLogs: [WorkLog] {
        let today = Calendar.current.startOfDay(for: Date())
        return member.workLogs.filter { Calendar.current.startOfDay(for: $0.date) == today }
    }

    var body: some View {
        Form {
            Section("Info") {
                LabeledContent("Role", value: member.role)
                LabeledContent("Company", value: member.company)
                LabeledContent("Phone", value: member.phone)
            }
            Section("Check-In / Out") {
                if member.checkedIn {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "clock.fill").foregroundColor(.green)
                            Text("Currently Checked In").fontWeight(.semibold).foregroundColor(.green)
                        }
                        if let active = activeLog {
                            Text("Project: \(active.project)").font(.caption)
                            Text("Location: \(active.location)").font(.caption).foregroundColor(.secondary)
                            Text("Since: \(active.timeIn, style: .time)").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    Button(role: .destructive) {
                        var m = member
                        if let idx = m.workLogs.firstIndex(where: { $0.timeOut == nil }) {
                            m.workLogs[idx].timeOut = Date()
                        }
                        m.checkedIn = false
                        m.currentProject = ""
                        store.updateCrewMember(m)
                    } label: {
                        Label("Check Out", systemImage: "arrow.right.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                } else {
                    Button { showCheckIn = true } label: {
                        Label("Check In", systemImage: "arrow.left.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.green)
                }
            }
            Section("Today's Summary") {
                if todayLogs.isEmpty {
                    Text("No hours logged today").foregroundColor(.secondary)
                } else {
                    ForEach(todayLogs) { log in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(log.project).font(.subheadline)
                                Text(log.location).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(log.hoursDisplay).foregroundColor(log.timeOut == nil ? .orange : .primary)
                        }
                    }
                    let total = todayLogs.filter { $0.timeOut != nil }.reduce(0) { $0 + $1.hoursWorked }
                    if total > 0 {
                        HStack {
                            Text("Total Today").fontWeight(.semibold)
                            Spacer()
                            Text(String(format: "%.2f hrs", total)).fontWeight(.semibold)
                        }
                    }
                }
            }
            if !member.phone.isEmpty {
                Section("Contact") {
                    Button {
                        let tel = "tel://" + member.phone.replacingOccurrences(of: "-", with: "")
                        if let url = URL(string: tel) { UIApplication.shared.open(url) }
                    } label: { Label("Call \(member.name)", systemImage: "phone.fill") }
                }
            }
        }
    }
}

struct CrewHoursLog: View {
    var member: CrewMember
    var store: AppStore
    @State private var showingAddLog = false

    var body: some View {
        VStack {
            Button { showingAddLog = true } label: {
                Label("Add Manual Entry", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity).padding()
                    .background(Color.blue.opacity(0.1)).cornerRadius(10).padding(.horizontal)
            }
            if member.workLogs.isEmpty {
                Spacer(); Text("No work logs yet").foregroundColor(.secondary); Spacer()
            } else {
                List {
                    let grouped = Dictionary(grouping: member.workLogs) { Calendar.current.startOfDay(for: $0.date) }
                    ForEach(grouped.keys.sorted(by: >), id: \.self) { date in
                        Section(header: Text(date, style: .date)) {
                            ForEach(grouped[date] ?? []) { log in WorkLogRowView(log: log) }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddLog) {
            AddWorkLogView(member: Binding(
                get: { store.crewMembers.first(where: { $0.id == member.id }) ?? member },
                set: { store.updateCrewMember($0) }
            ), projects: store.activeProjectNames + ["Office", "Unassigned"])
        }
    }
}

struct CrewTimesheet: View {
    var member: CrewMember

    var thisWeekDays: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today)
        let start = cal.date(byAdding: .day, value: -(weekday - 2), to: today) ?? today
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    func logsFor(day: Date) -> [WorkLog] {
        member.workLogs.filter { Calendar.current.startOfDay(for: $0.date) == day }
    }

    var body: some View {
        List {
            Section(header: Text("Daily — This Week")) {
                ForEach(thisWeekDays, id: \.self) { day in
                    let total = logsFor(day: day).filter { $0.timeOut != nil }.reduce(0) { $0 + $1.hoursWorked }
                    HStack {
                        Text(day, format: .dateTime.weekday(.wide).month().day()).font(.subheadline)
                        Spacer()
                        Text(total > 0 ? String(format: "%.2f hrs", total) : "—")
                            .foregroundColor(total > 0 ? .blue : .secondary)
                    }
                }
            }
            Section(header: Text("Weekly Total")) {
                let total = thisWeekDays.flatMap { logsFor(day: $0) }.filter { $0.timeOut != nil }.reduce(0) { $0 + $1.hoursWorked }
                HStack {
                    Text("This Week").fontWeight(.semibold)
                    Spacer()
                    Text(String(format: "%.2f hrs", total)).fontWeight(.bold).foregroundColor(.green)
                }
            }
        }
    }
}

struct CheckInSheet: View {
    @Binding var member: CrewMember
    let projects: [String]
    @Environment(\.dismiss) var dismiss
    @State private var selectedProject = ""
    @State private var locationMode = 0
    @State private var manualLocation = ""
    @State private var locationManager = LocationManager()

    var resolvedLocation: String {
        switch locationMode {
        case 1: return locationManager.locationString.isEmpty ? "Detecting..." : locationManager.locationString
        case 2: return manualLocation
        default: return selectedProject.isEmpty ? "Unassigned" : selectedProject
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Project") {
                    Picker("Project", selection: $selectedProject) {
                        Text("Select Project").tag("")
                        ForEach(projects, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section("Location") {
                    Picker("Source", selection: $locationMode) {
                        Text("From Project").tag(0); Text("GPS").tag(1); Text("Manual").tag(2)
                    }.pickerStyle(.segmented)
                    if locationMode == 1 {
                        HStack {
                            Text(locationManager.locationString.isEmpty ? "Tap Detect" : locationManager.locationString).foregroundColor(.secondary)
                            Spacer()
                            Button("Detect") { locationManager.requestLocation() }.font(.caption)
                        }
                    } else if locationMode == 2 {
                        TextField("Enter location", text: $manualLocation)
                    } else {
                        Text(selectedProject.isEmpty ? "Will use project name" : selectedProject).foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Check In — \(member.name)")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Check In") {
                        let log = WorkLog(date: Date(), project: selectedProject.isEmpty ? "Unassigned" : selectedProject, location: resolvedLocation, timeIn: Date())
                        member.workLogs.append(log)
                        member.checkedIn = true
                        member.currentProject = selectedProject
                        dismiss()
                    }
                }
            }
        }
    }
}

struct WorkLogRowView: View {
    let log: WorkLog
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(log.project).font(.subheadline).fontWeight(.semibold)
                Spacer()
                Text(log.hoursDisplay).foregroundColor(log.timeOut == nil ? .orange : .green)
            }
            Text(log.location).font(.caption).foregroundColor(.secondary)
            HStack {
                Text(log.timeIn, style: .time).font(.caption2)
                if let out = log.timeOut { Text("→").font(.caption2); Text(out, style: .time).font(.caption2) }
                else { Text("→ In Progress").font(.caption2).foregroundColor(.orange) }
            }
        }.padding(.vertical, 2)
    }
}

struct AddWorkLogView: View {
    @Binding var member: CrewMember
    let projects: [String]
    @Environment(\.dismiss) var dismiss
    @State private var locationManager = LocationManager()
    @State private var selectedProject = ""
    @State private var locationMode = 0
    @State private var manualLocation = ""
    @State private var timeIn = Date()
    @State private var timeOut = Date()
    @State private var includeTimeOut = false
    @State private var notes = ""

    var resolvedLocation: String {
        switch locationMode {
        case 1: return locationManager.locationString.isEmpty ? "Unknown" : locationManager.locationString
        case 2: return manualLocation
        default: return selectedProject.isEmpty ? "Unassigned" : selectedProject
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Project") {
                    Picker("Project", selection: $selectedProject) {
                        Text("Select Project").tag("")
                        ForEach(projects, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section("Location") {
                    Picker("Source", selection: $locationMode) {
                        Text("From Project").tag(0); Text("GPS").tag(1); Text("Manual").tag(2)
                    }.pickerStyle(.segmented)
                    if locationMode == 1 {
                        HStack {
                            Text(locationManager.locationString.isEmpty ? "Tap Detect" : locationManager.locationString).foregroundColor(.secondary)
                            Spacer()
                            Button("Detect") { locationManager.requestLocation() }.font(.caption)
                        }
                    } else if locationMode == 2 { TextField("Enter location", text: $manualLocation) }
                    else { Text(selectedProject.isEmpty ? "Will use project name" : selectedProject).foregroundColor(.secondary) }
                }
                Section("Time") {
                    DatePicker("Time In", selection: $timeIn, displayedComponents: [.hourAndMinute])
                    Toggle("Include Time Out", isOn: $includeTimeOut)
                    if includeTimeOut { DatePicker("Time Out", selection: $timeOut, displayedComponents: [.hourAndMinute]) }
                }
                Section("Notes") { TextField("Optional notes", text: $notes, axis: .vertical).lineLimit(3) }
            }
            .navigationTitle("Manual Entry")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        member.workLogs.append(WorkLog(date: Date(), project: selectedProject.isEmpty ? "Unassigned" : selectedProject, location: resolvedLocation, timeIn: timeIn, timeOut: includeTimeOut ? timeOut : nil, notes: notes))
                        dismiss()
                    }
                }
            }
        }
    }
}

struct EditCrewInfoView: View {
    @Binding var member: CrewMember
    var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var role = ""
    @State private var phone = ""
    @State private var company = ""
    let companies = ["Blair Ventures", "Integral Containment Systems"]

    var body: some View {
        NavigationView {
            Form {
                Section("Personal Info") {
                    TextField("Full Name", text: $name)
                    TextField("Role / Trade", text: $role)
                    TextField("Phone Number", text: $phone).keyboardType(.phonePad)
                }
                Section("Company") {
                    Picker("Company", selection: $company) {
                        ForEach(companies, id: \.self) { Text($0) }
                    }
                }
            }
            .navigationTitle("Edit \(member.name)")
            .onAppear { name = member.name; role = member.role; phone = member.phone; company = member.company }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        member.name = name; member.role = role; member.phone = phone; member.company = company
                        store.updateCrewMember(member)
                        dismiss()
                    }
                    .disabled(name.isEmpty || role.isEmpty)
                }
            }
        }
    }
}

struct AddCrewView: View {
    var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var role = ""
    @State private var phone = ""
    @State private var company = "Blair Ventures"
    let companies = ["Blair Ventures", "Integral Containment Systems"]

    var body: some View {
        NavigationView {
            Form {
                Section("Personal Info") {
                    TextField("Full Name", text: $name)
                    TextField("Role / Trade", text: $role)
                    TextField("Phone Number", text: $phone).keyboardType(.phonePad)
                }
                Section("Company") {
                    Picker("Company", selection: $company) { ForEach(companies, id: \.self) { Text($0) } }
                }
            }
            .navigationTitle("Add Crew Member")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        store.addCrewMember(CrewMember(name: name, role: role, phone: phone, company: company))
                        dismiss()
                    }
                    .disabled(name.isEmpty || role.isEmpty)
                }
            }
        }
    }
}
