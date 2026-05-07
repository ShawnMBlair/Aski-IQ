import Foundation

struct EstimateCalculationEngine {

    static func calculate(estimate: Estimate, materials: [MaterialItem], equipment: [EquipmentItem]) -> CalculationResult {
        var result = CalculationResult()
        var lineItems: [EstimateLineItem] = []
        let dims = estimate.dimensions
        let labor = estimate.laborConfig
        let pricing = estimate.pricingConfig

        switch estimate.projectType {
        case .shrinkWrap, .scaffoldWrap, .weatherProtection:
            result = calcShrinkWrap(dims: dims, labor: labor, pricing: pricing, materials: materials, equipment: equipment, lineItems: &lineItems)
        case .containmentEnclosure, .temporaryHoarding:
            result = calcContainment(dims: dims, labor: labor, pricing: pricing, materials: materials, equipment: equipment, lineItems: &lineItems)
        case .custom:
            result = calcCustom(dims: dims, labor: labor, lineItems: &lineItems)
        }

        let customMat = estimate.customLineItems.filter { $0.isIncluded && $0.category == "Material" }.reduce(0) { $0 + $1.total }
        let customLab = estimate.customLineItems.filter { $0.isIncluded && $0.category == "Labor" }.reduce(0) { $0 + $1.total }
        let customEq = estimate.customLineItems.filter { $0.isIncluded && $0.category == "Equipment" }.reduce(0) { $0 + $1.total }
        result.materialSubtotal += customMat
        result.laborSubtotal += customLab
        result.equipmentSubtotal += customEq
        lineItems.append(contentsOf: estimate.customLineItems.filter { $0.isIncluded })

        let base = result.materialSubtotal + result.laborSubtotal + result.equipmentSubtotal + result.subcontractSubtotal + result.deliverySubtotal + result.miscSubtotal
        result.wasteAllowance = result.materialSubtotal * (pricing.wastePercent / 100)
        result.contingency = (base + result.wasteAllowance) * (pricing.contingencyPercent / 100)
        result.overhead = (base + result.wasteAllowance + result.contingency) * (pricing.overheadPercent / 100)
        let costBeforeProfit = base + result.wasteAllowance + result.contingency + result.overhead
        result.totalCost = costBeforeProfit
        result.profit = costBeforeProfit * (pricing.profitPercent / 100)
        var sell = (costBeforeProfit + result.profit) * pricing.rushFactor * pricing.remoteLocationFactor
        if pricing.minimumCharge > 0 && sell < pricing.minimumCharge { sell = pricing.minimumCharge }
        if pricing.roundUpToNearest > 0 { sell = ceil(sell / pricing.roundUpToNearest) * pricing.roundUpToNearest }
        if pricing.applyTax { result.tax = sell * (pricing.taxPercent / 100); sell += result.tax }
        result.totalSell = sell
        result.grossMargin = sell > 0 ? ((sell - result.totalCost) / sell) * 100 : 0
        result.lineItems = lineItems
        return result
    }

    static func calcShrinkWrap(dims: ProjectDimensions, labor: LaborConfig, pricing: PricingConfig, materials: [MaterialItem], equipment: [EquipmentItem], lineItems: inout [EstimateLineItem]) -> CalculationResult {
        var r = CalculationResult()
        let surface = dims.totalSurfaceArea * dims.irregularGeometryFactor
        let wrapArea = surface * 1.15 * (1 + pricing.wastePercent / 100)
        let rolls = ceil(wrapArea / 500)
        let wrapCost = matCost("Shrink Wrap", materials, 85.0)
        lineItems.append(li("Material", "Shrink Wrap (9 mil)", rolls, "roll", wrapCost))
        r.materialSubtotal += rolls * wrapCost

        let strapping = dims.perimeterLength * Double(dims.numberOfLevels) * 3
        lineItems.append(li("Material", "Strapping", strapping, "ln ft", 0.12))
        r.materialSubtotal += strapping * 0.12

        let tape = ceil(surface / 400)
        let tapeCost = matCost("Tape", materials, 22.0)
        lineItems.append(li("Material", "Shrink Wrap Tape", tape, "roll", tapeCost))
        r.materialSubtotal += tape * tapeCost

        let zippers = Double(max(dims.accessPoints, 1))
        let zipCost = matCost("Zipper", materials, 45.0)
        lineItems.append(li("Material", "Zipper Access Doors", zippers, "each", zipCost))
        r.materialSubtotal += zippers * zipCost

        let propane = ceil(surface / 1500)
        lineItems.append(li("Consumables", "Propane Tanks", propane, "each", 35.0))
        r.materialSubtotal += propane * 35.0

        let baseH = surface * labor.shrinkWrapRatePerSqFt * labor.complexityFactor * labor.productivityFactor * labor.travelFactor * labor.weatherFactor
        let totalH = baseH + (baseH * labor.tearDownFactor) + labor.mobDemobHours
        r.estimatedLaborHours = totalH
        r.crewDays = ceil(totalH / (labor.shiftHours * Double(labor.crewSize)))
        let fmHours = r.crewDays * labor.shiftHours
        let instHours = max(totalH - fmHours, 0)
        lineItems.append(li("Labor", "Foreman", fmHours, "hour", labor.foremanRate))
        lineItems.append(li("Labor", "Installers", instHours, "hour", labor.laborRate))
        r.laborSubtotal += fmHours * labor.foremanRate + instHours * labor.laborRate

        let hgDays = r.crewDays
        let hgRate = eqRate("Heat Gun", equipment, 45.0)
        lineItems.append(li("Equipment", "Heat Gun", hgDays, "day", hgRate))
        r.equipmentSubtotal += hgDays * hgRate

        if dims.height > 4 {
            let liftDays = Int(r.crewDays)
            let liftCost: Double
            if let lift = findEq("Scissor Lift", equipment) {
                liftCost = lift.bestRate(forDays: liftDays)
            } else {
                liftCost = 350.0 * Double(liftDays)
            }
            lineItems.append(li("Equipment", "Scissor Lift", 1, "lot", liftCost))
            r.equipmentSubtotal += liftCost
        }

        return r
    }

    static func calcContainment(dims: ProjectDimensions, labor: LaborConfig, pricing: PricingConfig, materials: [MaterialItem], equipment: [EquipmentItem], lineItems: inout [EstimateLineItem]) -> CalculationResult {
        var r = CalculationResult()
        let polyArea = (dims.wallArea + dims.floorArea) * 1.15 * (1 + pricing.wastePercent / 100)
        let polyRolls = ceil(polyArea / 800)
        let polyCost = matCost("6 Mil Poly", materials, 55.0)
        lineItems.append(li("Material", "6 Mil Poly Film", polyRolls, "roll", polyCost))
        r.materialSubtotal += polyRolls * polyCost

        let framingFt = dims.perimeterLength * Double(dims.numberOfLevels) * 3.5
        let lumberCost = matCost("Lumber", materials, 1.85)
        lineItems.append(li("Material", "Framing Lumber (2x4)", framingFt, "ln ft", lumberCost))
        r.materialSubtotal += framingFt * lumberCost

        let tape = ceil((dims.wallArea + dims.floorArea) / 300)
        let tapeCost = matCost("Poly Tape", materials, 18.0)
        lineItems.append(li("Material", "Poly Tape", tape, "roll", tapeCost))
        r.materialSubtotal += tape * tapeCost

        let zippers = Double(max(dims.accessPoints, 1))
        let zipCost = matCost("Zipper", materials, 45.0)
        lineItems.append(li("Material", "Zipper Access Doors", zippers, "each", zipCost))
        r.materialSubtotal += zippers * zipCost

        let floorProt = dims.floorArea
        let fpCost = matCost("Ram Board", materials, 0.45)
        lineItems.append(li("Material", "Floor Protection", floorProt, "sq ft", fpCost))
        r.materialSubtotal += floorProt * fpCost

        let fasteners = ceil(framingFt / 100)
        lineItems.append(li("Material", "Fasteners", fasteners, "bag", 18.0))
        r.materialSubtotal += fasteners * 18.0

        let baseH = (framingFt * labor.containmentFrameRatePerLnFt + polyArea * labor.polyInstallRatePerSqFt) * labor.complexityFactor * labor.productivityFactor
        let totalH = baseH + (baseH * labor.tearDownFactor) + labor.mobDemobHours
        r.estimatedLaborHours = totalH
        r.crewDays = ceil(totalH / (labor.shiftHours * Double(labor.crewSize)))
        let fmHours = r.crewDays * labor.shiftHours
        let instHours = max(totalH - fmHours, 0)
        lineItems.append(li("Labor", "Foreman", fmHours, "hour", labor.foremanRate))
        lineItems.append(li("Labor", "Installers", instHours, "hour", labor.laborRate))
        r.laborSubtotal += fmHours * labor.foremanRate + instHours * labor.laborRate

        if dims.duration > 0 {
            let namDays = dims.duration
            let namCost: Double
            if let nam = findEq("Negative Air", equipment) {
                namCost = nam.bestRate(forDays: namDays)
            } else {
                namCost = 85.0 * Double(namDays)
            }
            lineItems.append(li("Equipment", "Negative Air Machine", 1, "lot", namCost))
            r.equipmentSubtotal += namCost
        }

        return r
    }

    static func calcCustom(dims: ProjectDimensions, labor: LaborConfig, lineItems: inout [EstimateLineItem]) -> CalculationResult {
        var r = CalculationResult()
        let h = dims.totalSurfaceArea * labor.shrinkWrapRatePerSqFt * labor.complexityFactor + labor.mobDemobHours
        r.estimatedLaborHours = h
        r.crewDays = ceil(h / (labor.shiftHours * Double(labor.crewSize)))
        lineItems.append(li("Labor", "Labor (Custom)", h, "hour", labor.laborRate))
        r.laborSubtotal = h * labor.laborRate
        return r
    }

    static func li(_ cat: String, _ desc: String, _ qty: Double, _ unit: String, _ cost: Double) -> EstimateLineItem {
        EstimateLineItem(category: cat, description: desc, quantity: qty, unit: unit, unitCost: cost)
    }

    static func matCost(_ name: String, _ mats: [MaterialItem], _ def: Double) -> Double {
        mats.first { $0.name.localizedCaseInsensitiveContains(name) }?.unitCost ?? def
    }

    static func eqRate(_ name: String, _ equip: [EquipmentItem], _ def: Double) -> Double {
        equip.first { $0.name.localizedCaseInsensitiveContains(name) }?.dailyRate ?? def
    }

    static func findEq(_ name: String, _ equip: [EquipmentItem]) -> EquipmentItem? {
        equip.first { $0.name.localizedCaseInsensitiveContains(name) }
    }
}
