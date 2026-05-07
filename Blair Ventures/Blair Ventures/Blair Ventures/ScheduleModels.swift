import Foundation
import SwiftUI

enum JobStatus: String, CaseIterable, Codable {
    case draft = "Draft"
    case quotePending = "Quote Pending"
    case tentative = "Tentative"
    case scheduled = "Scheduled"
    case confirmed = "Confirmed"
    case mobilizing = "Mobilizing"
    case inProgress = "In Progress"
    case onHold = "On Hold"
    case delayed = "Delayed"
    case completed = "Completed"
    case invoiced = "Invoiced"
    case closed = "Closed"

    var color: Color {
        switch self {
        case .draft: return .gray
        case .quotePending: return .purple
        case .tentative: return Color(.systemIndigo)
        case .scheduled: return .blue
        case .confirmed: return Color(.systemTeal)
        case .mobilizing: return .orange
        case .inProgress: return .orange
        case .onHold: return .yellow
        case .delayed: return .red
        case .completed: return .green
        case .invoiced: return Color(.systemMint)
        case .closed: return .gray
        }
    }
}

enum JobPriority: String, CaseIterable, Codable {
    case low = "Low"
    case normal = "Normal"
    case high = "High"
    case urgent = "Urgent"

    var color: Color {
        switch self {
        case .low: return .gray
        case .normal: return .blue
        case .high: return .orange
        case .urgent: return .red
        }
    }
}

enum ServiceType: String, CaseIterable, Codable {
    case shrinkWrap = "Shrink Wrap"
    case containment = "Containment Enclosure"
    case scaffoldWrap = "Scaffold Wrap"
    case weatherProtection = "Weather Protection"
    case temporaryHoarding = "Temporary Hoarding"
    case custom = "Custom"

    var icon: String {
        switch self {
        case .shrinkWrap: return "wind"
        case .containment: return "square.dashed"
        case .scaffoldWrap: return "building.columns"
        case .weatherProtection: return "cloud.rain"
        case .temporaryHoarding: return "rectangle.split.3x1"
        case .custom: return "wrench.and.screwdriver"
        }
    }
}

enum DelayReason: String, CaseIterable, Codable {
    case weather = "Weather"
    case crewAvailability = "Crew Availability"
    case accessIssue = "Access Issue"
    case clientDelay = "Client Delay"
    case materialShortage = "Material Shortage"
    case equipmentIssue = "Equipment Issue"
    case safetyIssue = "Safety Issue"
    case scopeChange = "Scope Change"
    case other = "Other"
}

enum ShiftType: String, CaseIterable, Codable {
    case day = "Day Shift"
    case night = "Night Shift"
    case rotating = "Rotating"
}

struct ScheduleJob: Identifiable, Codable {
    var id = UUID()
    var jobNumber: String = ""
    var title: String = ""
    var clientName: String = ""
    var siteAddress: String = ""
    var region: String = ""
    var serviceType: ServiceType = .shrinkWrap
    var status: JobStatus = .draft
    var priority: JobPriority = .normal
    var projectManager: String = "Shawn Blair"
    var supervisor: String = ""
    var assignedCrew: [String] = []
    var crewSize: Int = 3
    var company: String = "Blair Ventures"
    var scopeDescription: String = ""
    var estimatedSqFt: Double = 0
    var numberOfLevels: Int = 1
    var accessPoints: Int = 1
    var scaffoldRequired: Bool = false
    var containmentOnly: Bool = false
    var tentativeStartDate: Date = Date()
    var confirmedStartDate: Date? = nil
    var expectedEndDate: Date = Date().addingTimeInterval(7 * 24 * 3600)
    var actualEndDate: Date? = nil
    var shiftType: ShiftType = .day
    var workingHours: String = "7:00 AM - 5:00 PM"
    var weatherDelayDays: Int = 0
    var delayReason: DelayReason? = nil
    var holdReason: String = ""
    var generalNotes: String = ""
    var fieldNotes: String = ""
    var delayNotes: String = ""
    var quoteNumber: String = ""
    var poNumber: String = ""
    var budgetValue: Double = 0
    var hazardNotes: String = ""
    var accessInstructions: String = ""
    var orientationRequired: Bool = false
    var ppeRequirements: String = ""
    var createdDate: Date = Date()
    var modifiedDate: Date = Date()

    var durationDays: Int {
        Calendar.current.dateComponents([.day], from: tentativeStartDate, to: expectedEndDate).day ?? 0
    }

    var isActive: Bool {
        [.mobilizing, .inProgress, .confirmed, .scheduled].contains(status)
    }
}

@Observable
class ScheduleViewModel {
    var jobs: [ScheduleJob] = []
    private let key = "schedule_jobs"

    init() {
        load()
        if jobs.isEmpty { seedData() }
    }

    func addJob(_ job: ScheduleJob) {
        var j = job
        j.jobNumber = "JOB-\(String(format: "%04d", jobs.count + 1001))"
        j.createdDate = Date()
        jobs.insert(j, at: 0)
        save()
    }

    func updateJob(_ job: ScheduleJob) {
        if let i = jobs.firstIndex(where: { $0.id == job.id }) {
            var j = job
            j.modifiedDate = Date()
            jobs[i] = j
        }
        save()
    }

    func deleteJob(_ job: ScheduleJob) {
        jobs.removeAll { $0.id == job.id }
        save()
    }

    func duplicateJob(_ job: ScheduleJob) {
        var copy = job
        copy.id = UUID()
        copy.jobNumber = "JOB-\(String(format: "%04d", jobs.count + 1001))"
        copy.title = "\(job.title) (Copy)"
        copy.status = .draft
        copy.createdDate = Date()
        jobs.insert(copy, at: 0)
        save()
    }

    func jobsFor(date: Date) -> [ScheduleJob] {
        let cal = Calendar.current
        return jobs.filter {
            let start = cal.startOfDay(for: $0.tentativeStartDate)
            let end = cal.startOfDay(for: $0.expectedEndDate)
            let day = cal.startOfDay(for: date)
            return day >= start && day <= end
        }
    }

    func jobsThisWeek() -> [ScheduleJob] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekEnd = cal.date(byAdding: .day, value: 7, to: today) ?? today
        return jobs.filter {
            $0.tentativeStartDate >= today && $0.tentativeStartDate <= weekEnd
        }
    }

    var activeJobs: [ScheduleJob] { jobs.filter { $0.isActive } }
    var delayedJobs: [ScheduleJob] { jobs.filter { $0.status == .delayed } }
    var unassignedJobs: [ScheduleJob] {
        jobs.filter { $0.assignedCrew.isEmpty && $0.status != .completed && $0.status != .closed }
    }
    var todayJobs: [ScheduleJob] { jobsFor(date: Date()) }

    func save() {
        if let d = try? JSONEncoder().encode(jobs) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }

    func load() {
        if let d = UserDefaults.standard.data(forKey: key),
           let v = try? JSONDecoder().decode([ScheduleJob].self, from: d) {
            jobs = v
        }
    }

    func seedData() {
        let today = Date()
        let cal = Calendar.current

        func makeJob(_ num: String, _ title: String, _ client: String, _ site: String,
                     _ service: ServiceType, _ status: JobStatus, _ priority: JobPriority,
                     _ supervisor: String, _ crew: [String], _ crewSize: Int,
                     _ startOffset: Int, _ endOffset: Int, _ sqft: Double,
                     _ scope: String, _ budget: Double, _ company: String) -> ScheduleJob {
            var j = ScheduleJob()
            j.jobNumber = num; j.title = title; j.clientName = client
            j.siteAddress = site; j.serviceType = service; j.status = status
            j.priority = priority; j.supervisor = supervisor; j.assignedCrew = crew
            j.crewSize = crewSize; j.estimatedSqFt = sqft; j.scopeDescription = scope
            j.budgetValue = budget; j.company = company
            j.tentativeStartDate = cal.date(byAdding: .day, value: startOffset, to: today) ?? today
            j.expectedEndDate = cal.date(byAdding: .day, value: endOffset, to: today) ?? today
            if status == .delayed { j.delayReason = .weather; j.delayNotes = "High winds forecast." }
            return j
        }

        jobs = [
            makeJob("JOB-1001", "Heidelberg CCUS Enclosure", "Heidelberg Materials", "Edmonton, AB",
                    .containment, .inProgress, .high, "Darren", ["Jim", "Darren", "Crew A"], 4,
                    -2, 12, 8500, "Turnkey containment for CCUS project.", 185000, "Integral Containment Systems"),
            makeJob("JOB-1002", "NexGen Core Yard Coverall", "NexGen Energy", "Saskatchewan",
                    .shrinkWrap, .scheduled, .normal, "Jim", ["Jim", "Crew B"], 3,
                    5, 20, 12000, "Fabric coverall building systems.", 245000, "Blair Ventures"),
            makeJob("JOB-1003", "Scaffold Wrap — Refinery Unit 4", "Strathcona Refinery", "Strathcona County, AB",
                    .scaffoldWrap, .confirmed, .urgent, "Darren", ["Darren", "Crew C"], 5,
                    3, 10, 6200, "Full scaffold shrink wrap for turnaround.", 92000, "Integral Containment Systems"),
            makeJob("JOB-1004", "Weather Protection — Warehouse Roof", "Parkland Corp", "Red Deer, AB",
                    .weatherProtection, .delayed, .high, "Jim", [], 3,
                    -1, 6, 4400, "Roof weather protection.", 55000, "Blair Ventures"),
            makeJob("JOB-1005", "Interior Dust Containment", "PCL Construction", "Calgary, AB",
                    .containment, .draft, .normal, "", [], 2,
                    14, 19, 2200, "Interior poly containment.", 18500, "Integral Containment Systems")
        ]
        save()
    }
}
struct SimpleCrew: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var role: String
    var phone: String
    var company: String
}
