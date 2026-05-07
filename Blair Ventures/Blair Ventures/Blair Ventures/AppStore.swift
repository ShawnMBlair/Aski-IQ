import Foundation
import SwiftUI
import Observation

@Observable
class AppStore {

    var projects: [Project] = []
    var crewMembers: [CrewMember] = []
    var scheduleJobs: [ScheduleJob] = []
    var estimates: [Estimate] = []
    var safetyForms: [SafetyForm] = []
    var orientations: [WorkerOrientation] = []
    var certificates: [SafetyCertificate] = []
    var safetyDocuments: [SafetyDocument] = []
    var materials: [MaterialItem] = []
    var equipment: [EquipmentItem] = []
    var companySettings: CompanySettings = CompanySettings()
    var estimateTemplates: [EstimateTemplate] = []

    var projectNames: [String] { projects.map { $0.name } }
    var crewNames: [String] { crewMembers.map { $0.name } }
    var activeProjectNames: [String] {
        projects.filter { $0.status == .active || $0.status == .pending }.map { $0.name }
    }

    init() {
        load()
        if projects.isEmpty { seedProjects() }
        if crewMembers.isEmpty { seedCrew() }
        if scheduleJobs.isEmpty { seedJobs() }
        if materials.isEmpty { seedMaterials() }
        if equipment.isEmpty { seedEquipment() }
        if estimateTemplates.isEmpty { seedEstimateTemplates() }
    }

    // MARK: - Projects
    func addProject(_ p: Project) { projects.insert(p, at: 0); save() }
    func updateProject(_ p: Project) {
        if let i = projects.firstIndex(where: { $0.id == p.id }) { projects[i] = p }
        save()
    }
    func deleteProject(_ p: Project) { projects.removeAll { $0.id == p.id }; save() }

    // MARK: - Crew
    func addCrewMember(_ m: CrewMember) { crewMembers.insert(m, at: 0); save() }
    func updateCrewMember(_ m: CrewMember) {
        if let i = crewMembers.firstIndex(where: { $0.id == m.id }) { crewMembers[i] = m }
        save()
    }
    func deleteCrewMember(at offsets: IndexSet) { crewMembers.remove(atOffsets: offsets); save() }

    // MARK: - Schedule Jobs
    func addJob(_ job: ScheduleJob) {
        var j = job
        j.jobNumber = "JOB-\(String(format: "%04d", scheduleJobs.count + 1001))"
        j.createdDate = Date()
        scheduleJobs.insert(j, at: 0)
        save()
    }
    func updateJob(_ job: ScheduleJob) {
        if let i = scheduleJobs.firstIndex(where: { $0.id == job.id }) {
            var j = job; j.modifiedDate = Date(); scheduleJobs[i] = j
        }
        save()
    }
    func deleteJob(_ job: ScheduleJob) { scheduleJobs.removeAll { $0.id == job.id }; save() }
    func duplicateJob(_ job: ScheduleJob) {
        var copy = job
        copy.id = UUID()
        copy.jobNumber = "JOB-\(String(format: "%04d", scheduleJobs.count + 1001))"
        copy.title = "\(job.title) (Copy)"
        copy.status = .draft
        copy.createdDate = Date()
        scheduleJobs.insert(copy, at: 0)
        save()
    }
    func jobsFor(date: Date) -> [ScheduleJob] {
        let cal = Calendar.current
        return scheduleJobs.filter {
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
        return scheduleJobs.filter { $0.tentativeStartDate >= today && $0.tentativeStartDate <= weekEnd }
    }
    var activeJobs: [ScheduleJob] { scheduleJobs.filter { $0.isActive } }
    var delayedJobs: [ScheduleJob] { scheduleJobs.filter { $0.status == .delayed } }
    var unassignedJobs: [ScheduleJob] { scheduleJobs.filter { $0.assignedCrew.isEmpty && $0.status != .completed && $0.status != .closed } }
    var todayJobs: [ScheduleJob] { jobsFor(date: Date()) }

    // MARK: - Estimates
    func addEstimate(_ e: Estimate) {
        var est = e
        est.estimateNumber = "\(companySettings.estimatePrefix)-\(companySettings.nextEstimateNumber)"
        companySettings.nextEstimateNumber += 1
        estimates.insert(est, at: 0)
        save()
    }
    func updateEstimate(_ e: Estimate) {
        if let i = estimates.firstIndex(where: { $0.id == e.id }) {
            var est = e; est.modifiedDate = Date(); estimates[i] = est
        }
        save()
    }
    func deleteEstimate(_ e: Estimate) { estimates.removeAll { $0.id == e.id }; save() }
    func duplicateEstimate(_ e: Estimate) {
        var copy = e
        copy.id = UUID()
        copy.estimateNumber = "\(companySettings.estimatePrefix)-\(companySettings.nextEstimateNumber)"
        copy.projectName = "\(e.projectName) (Copy)"
        copy.status = .draft
        copy.createdDate = Date()
        copy.modifiedDate = Date()
        companySettings.nextEstimateNumber += 1
        estimates.insert(copy, at: 0)
        save()
    }
    func calculateEstimate(_ e: Estimate) -> CalculationResult {
        EstimateCalculationEngine.calculate(estimate: e, materials: materials, equipment: equipment)
    }

    // MARK: - Safety
    func addSafetyForm(_ f: SafetyForm) { safetyForms.insert(f, at: 0); save() }
    func updateSafetyForm(_ f: SafetyForm) {
        if let i = safetyForms.firstIndex(where: { $0.id == f.id }) { safetyForms[i] = f }
        save()
    }
    func deleteSafetyForm(at offsets: IndexSet) { safetyForms.remove(atOffsets: offsets); save() }
    func addOrientation(_ o: WorkerOrientation) { orientations.insert(o, at: 0); save() }
    func deleteOrientation(at offsets: IndexSet) { orientations.remove(atOffsets: offsets); save() }
    func addCertificate(_ c: SafetyCertificate) { certificates.insert(c, at: 0); save() }
    func deleteCertificate(at offsets: IndexSet) { certificates.remove(atOffsets: offsets); save() }
    func addDocument(_ d: SafetyDocument) { safetyDocuments.insert(d, at: 0); save() }
    func deleteDocument(at offsets: IndexSet) { safetyDocuments.remove(atOffsets: offsets); save() }

    // MARK: - Persistence
    func save() {
        enc(projects, "app_projects")
        enc(scheduleJobs, "app_jobs")
        enc(estimates, "app_estimates")
        enc(safetyForms, "app_safetyForms")
        enc(orientations, "app_orientations")
        enc(certificates, "app_certs")
        enc(safetyDocuments, "app_docs")
        enc(materials, "app_materials")
        enc(equipment, "app_equipment")
        enc(companySettings, "app_settings")
        enc(estimateTemplates, "app_templates")
        let simple = crewMembers.map { SimpleCrew(id: $0.id, name: $0.name, role: $0.role, phone: $0.phone, company: $0.company) }
        enc(simple, "app_crew")
    }

    func load() {
        projects = dec([Project].self, "app_projects") ?? []
        scheduleJobs = dec([ScheduleJob].self, "app_jobs") ?? []
        estimates = dec([Estimate].self, "app_estimates") ?? []
        safetyForms = dec([SafetyForm].self, "app_safetyForms") ?? []
        orientations = dec([WorkerOrientation].self, "app_orientations") ?? []
        certificates = dec([SafetyCertificate].self, "app_certs") ?? []
        safetyDocuments = dec([SafetyDocument].self, "app_docs") ?? []
        materials = dec([MaterialItem].self, "app_materials") ?? []
        equipment = dec([EquipmentItem].self, "app_equipment") ?? []
        companySettings = dec(CompanySettings.self, "app_settings") ?? CompanySettings()
        estimateTemplates = dec([EstimateTemplate].self, "app_templates") ?? []
        if let simple = dec([SimpleCrew].self, "app_crew") {
            crewMembers = simple.map { CrewMember(name: $0.name, role: $0.role, phone: $0.phone, company: $0.company) }
        }
    }

    private func enc<T: Encodable>(_ v: T, _ key: String) {
        if let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d, forKey: key) }
    }
    private func dec<T: Decodable>(_ t: T.Type, _ key: String) -> T? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(t, from: d)
    }

    // MARK: - Seed Data
    func seedProjects() {
        projects = [
            Project(name: "Heidelberg CCUS", client: "Heidelberg Materials", location: "Edmonton, AB", status: .active, startDate: "2026-04-01", endDate: "2026-07-31", notes: "Turnkey bid for three Quonset-style buildings"),
            Project(name: "NexGen Core Yard", client: "NexGen Energy", location: "Saskatchewan", status: .pending, startDate: "2026-05-01", endDate: "2026-09-30", notes: "Fabric coverall building systems")
        ]
        save()
    }

    func seedCrew() {
        crewMembers = [
            CrewMember(name: "Jim", role: "Operations Manager", phone: "780-555-0101", company: "Blair Ventures"),
            CrewMember(name: "Darren", role: "Field Manager", phone: "780-555-0102", company: "Integral Containment Systems"),
            CrewMember(name: "Stephanie", role: "AP/AR", phone: "780-555-0103", company: "Blair Ventures"),
            CrewMember(name: "Helen", role: "Payroll / Bookkeeping", phone: "780-555-0104", company: "Blair Ventures")
        ]
        save()
    }

    func seedJobs() {
        let today = Date()
        let cal = Calendar.current

        func makeJob(_ num: String, _ title: String, _ client: String, _ site: String,
                     _ svc: ServiceType, _ stat: JobStatus, _ pri: JobPriority,
                     _ sup: String, _ crew: [String], _ size: Int,
                     _ s: Int, _ e: Int, _ sqft: Double,
                     _ scope: String, _ budget: Double, _ co: String) -> ScheduleJob {
            var j = ScheduleJob()
            j.jobNumber = num; j.title = title; j.clientName = client; j.siteAddress = site
            j.serviceType = svc; j.status = stat; j.priority = pri; j.supervisor = sup
            j.assignedCrew = crew; j.crewSize = size; j.estimatedSqFt = sqft
            j.scopeDescription = scope; j.budgetValue = budget; j.company = co
            j.tentativeStartDate = cal.date(byAdding: .day, value: s, to: today) ?? today
            j.expectedEndDate = cal.date(byAdding: .day, value: e, to: today) ?? today
            if stat == .delayed { j.delayReason = .weather; j.delayNotes = "High winds forecast." }
            return j
        }

        scheduleJobs = [
            makeJob("JOB-1001","Heidelberg CCUS Enclosure","Heidelberg Materials","Edmonton, AB",.containment,.inProgress,.high,"Darren",["Jim","Darren"],4,-2,12,8500,"Turnkey containment.",185000,"Integral Containment Systems"),
            makeJob("JOB-1002","NexGen Core Yard Coverall","NexGen Energy","Saskatchewan",.shrinkWrap,.scheduled,.normal,"Jim",["Jim"],3,5,20,12000,"Fabric coverall.",245000,"Blair Ventures"),
            makeJob("JOB-1003","Scaffold Wrap Refinery Unit 4","Strathcona Refinery","Strathcona County, AB",.scaffoldWrap,.confirmed,.urgent,"Darren",["Darren"],5,3,10,6200,"Full scaffold wrap.",92000,"Integral Containment Systems"),
            makeJob("JOB-1004","Weather Protection Warehouse","Parkland Corp","Red Deer, AB",.weatherProtection,.delayed,.high,"Jim",[],3,-1,6,4400,"Roof protection.",55000,"Blair Ventures"),
            makeJob("JOB-1005","Interior Dust Containment","PCL Construction","Calgary, AB",.containment,.draft,.normal,"",[],2,14,19,2200,"Interior poly containment.",18500,"Integral Containment Systems")
        ]
        save()
    }

    func seedMaterials() {
        materials = [
            MaterialItem(name: "Shrink Wrap 9 mil", category: .shrinkWrap, unit: .roll, unitCost: 85, coverageRate: 500, wasteFactor: 10),
            MaterialItem(name: "Shrink Wrap 7 mil", category: .shrinkWrap, unit: .roll, unitCost: 65, coverageRate: 500, wasteFactor: 10),
            MaterialItem(name: "Shrink Wrap 12 mil FR", category: .shrinkWrap, unit: .roll, unitCost: 115, coverageRate: 400, wasteFactor: 10),
            MaterialItem(name: "Shrink Wrap Tape", category: .tape, unit: .roll, unitCost: 22, coverageRate: 150, wasteFactor: 5),
            MaterialItem(name: "Poly Tape", category: .tape, unit: .roll, unitCost: 18, coverageRate: 150, wasteFactor: 5),
            MaterialItem(name: "Strapping", category: .hardware, unit: .lnft, unitCost: 0.12, coverageRate: 1, wasteFactor: 5),
            MaterialItem(name: "Zipper Door Kit", category: .access, unit: .each, unitCost: 45, coverageRate: 1, wasteFactor: 0),
            MaterialItem(name: "6 Mil Poly", category: .poly, unit: .roll, unitCost: 55, coverageRate: 800, wasteFactor: 15),
            MaterialItem(name: "Fire Rated Poly", category: .poly, unit: .roll, unitCost: 95, coverageRate: 600, wasteFactor: 15),
            MaterialItem(name: "Lumber 2x4", category: .framing, unit: .lnft, unitCost: 1.85, coverageRate: 1, wasteFactor: 10),
            MaterialItem(name: "Ram Board", category: .protection, unit: .sqft, unitCost: 0.45, coverageRate: 1, wasteFactor: 5),
            MaterialItem(name: "Propane Tank", category: .consumables, unit: .each, unitCost: 35, coverageRate: 1, wasteFactor: 0),
            MaterialItem(name: "Fasteners", category: .hardware, unit: .bag, unitCost: 18, coverageRate: 100, wasteFactor: 5)
        ]
        save()
    }

    func seedEquipment() {
        equipment = [
            EquipmentItem(name: "Heat Gun", dailyRate: 45, weeklyRate: 175, monthlyRate: 450),
            EquipmentItem(name: "Scissor Lift", dailyRate: 350, weeklyRate: 950, monthlyRate: 2800),
            EquipmentItem(name: "Boom Lift", dailyRate: 550, weeklyRate: 1600, monthlyRate: 4500),
            EquipmentItem(name: "Negative Air Machine", dailyRate: 85, weeklyRate: 275, monthlyRate: 750),
            EquipmentItem(name: "HEPA Scrubber", dailyRate: 75, weeklyRate: 250, monthlyRate: 650),
            EquipmentItem(name: "Generator", dailyRate: 175, weeklyRate: 550, monthlyRate: 1500),
            EquipmentItem(name: "Telehandler", dailyRate: 650, weeklyRate: 1900, monthlyRate: 5500),
            EquipmentItem(name: "Scaffold per lift", dailyRate: 25, weeklyRate: 80, monthlyRate: 220)
        ]
        save()
    }

    func seedEstimateTemplates() {
        estimateTemplates = [
            EstimateTemplate(name: "Small Interior Dust Containment", projectType: .containmentEnclosure, description: "Standard small room containment"),
            EstimateTemplate(name: "Scaffold Shrink Wrap", projectType: .scaffoldWrap, description: "Full scaffold wrap with access doors"),
            EstimateTemplate(name: "Temporary Roof Protection", projectType: .weatherProtection, description: "Roof area weather protection"),
            EstimateTemplate(name: "Equipment Preservation Wrap", projectType: .shrinkWrap, description: "Industrial equipment shrink wrap"),
            EstimateTemplate(name: "Negative Air Containment Room", projectType: .containmentEnclosure, description: "Full containment with negative air")
        ]
        save()
    }
}
