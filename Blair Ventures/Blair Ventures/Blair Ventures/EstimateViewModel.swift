import Foundation
import Observation

@Observable
class EstimateViewModel {
    var estimates: [Estimate] = []
    var templates: [EstimateTemplate] = []
    var materials: [MaterialItem] = []
    var equipment: [EquipmentItem] = []
    var companySettings: CompanySettings = CompanySettings()

    init() {
        load()
        if materials.isEmpty { seedMaterials() }
        if equipment.isEmpty { seedEquipment() }
        if templates.isEmpty { seedTemplates() }
    }

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

    func deleteEstimate(_ e: Estimate) {
        estimates.removeAll { $0.id == e.id }
        save()
    }

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

    func calculate(_ e: Estimate) -> CalculationResult {
        EstimateCalculationEngine.calculate(estimate: e, materials: materials, equipment: equipment)
    }

    func save() {
        if let d = try? JSONEncoder().encode(estimates) { UserDefaults.standard.set(d, forKey: "estimates") }
        if let d = try? JSONEncoder().encode(companySettings) { UserDefaults.standard.set(d, forKey: "companySettings") }
        if let d = try? JSONEncoder().encode(materials) { UserDefaults.standard.set(d, forKey: "materials") }
        if let d = try? JSONEncoder().encode(equipment) { UserDefaults.standard.set(d, forKey: "equipment") }
    }

    func load() {
        if let d = UserDefaults.standard.data(forKey: "estimates"), let v = try? JSONDecoder().decode([Estimate].self, from: d) { estimates = v }
        if let d = UserDefaults.standard.data(forKey: "companySettings"), let v = try? JSONDecoder().decode(CompanySettings.self, from: d) { companySettings = v }
        if let d = UserDefaults.standard.data(forKey: "materials"), let v = try? JSONDecoder().decode([MaterialItem].self, from: d) { materials = v }
        if let d = UserDefaults.standard.data(forKey: "equipment"), let v = try? JSONDecoder().decode([EquipmentItem].self, from: d) { equipment = v }
    }

    func seedMaterials() {
        materials = [
            MaterialItem(name: "Shrink Wrap 9 mil", category: .shrinkWrap, unit: .roll, unitCost: 85, coverageRate: 500, wasteFactor: 10),
            MaterialItem(name: "Shrink Wrap 7 mil", category: .shrinkWrap, unit: .roll, unitCost: 65, coverageRate: 500, wasteFactor: 10),
            MaterialItem(name: "Shrink Wrap 12 mil FR", category: .shrinkWrap, unit: .roll, unitCost: 115, coverageRate: 400, wasteFactor: 10),
            MaterialItem(name: "Shrink Wrap Tape", category: .tape, unit: .roll, unitCost: 22, coverageRate: 150, wasteFactor: 5),
            MaterialItem(name: "Poly Tape", category: .tape, unit: .roll, unitCost: 18, coverageRate: 150, wasteFactor: 5),
            MaterialItem(name: "Strapping", category: .hardware, unit: .lnft, unitCost: 0.12, coverageRate: 1, wasteFactor: 5),
            MaterialItem(name: "Buckles", category: .hardware, unit: .each, unitCost: 0.45, coverageRate: 1, wasteFactor: 5),
            MaterialItem(name: "Zipper Door Kit", category: .access, unit: .each, unitCost: 45, coverageRate: 1, wasteFactor: 0),
            MaterialItem(name: "6 Mil Poly", category: .poly, unit: .roll, unitCost: 55, coverageRate: 800, wasteFactor: 15),
            MaterialItem(name: "Fire Rated Poly", category: .poly, unit: .roll, unitCost: 95, coverageRate: 600, wasteFactor: 15),
            MaterialItem(name: "Lumber 2x4", category: .framing, unit: .lnft, unitCost: 1.85, coverageRate: 1, wasteFactor: 10),
            MaterialItem(name: "Ram Board", category: .protection, unit: .sqft, unitCost: 0.45, coverageRate: 1, wasteFactor: 5),
            MaterialItem(name: "Masonite", category: .protection, unit: .sqft, unitCost: 0.65, coverageRate: 1, wasteFactor: 5),
            MaterialItem(name: "Propane Tank", category: .consumables, unit: .each, unitCost: 35, coverageRate: 1, wasteFactor: 0),
            MaterialItem(name: "Fasteners", category: .hardware, unit: .bag, unitCost: 18, coverageRate: 100, wasteFactor: 5),
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
            EquipmentItem(name: "Scaffold per lift", dailyRate: 25, weeklyRate: 80, monthlyRate: 220),
        ]
        save()
    }

    func seedTemplates() {
        templates = [
            EstimateTemplate(name: "Small Interior Dust Containment", projectType: .containmentEnclosure, description: "Standard small room containment"),
            EstimateTemplate(name: "Scaffold Shrink Wrap", projectType: .scaffoldWrap, description: "Full scaffold wrap with access doors"),
            EstimateTemplate(name: "Temporary Roof Protection", projectType: .weatherProtection, description: "Roof area weather protection"),
            EstimateTemplate(name: "Equipment Preservation Wrap", projectType: .shrinkWrap, description: "Industrial equipment shrink wrap"),
            EstimateTemplate(name: "Negative Air Containment Room", projectType: .containmentEnclosure, description: "Full containment with negative air"),
        ]
    }
}
