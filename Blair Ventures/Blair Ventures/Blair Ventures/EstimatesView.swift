import SwiftUI

struct EstimatesView: View {
    var store: AppStore
    @State private var showNew = false
    @State private var showSettings = false
    @State private var search = ""
    @State private var filterStatus: EstimateStatus? = nil

    var filtered: [Estimate] {
        var r = store.estimates
        if !search.isEmpty { r = r.filter { $0.projectName.localizedCaseInsensitiveContains(search) || $0.clientName.localizedCaseInsensitiveContains(search) || $0.estimateNumber.localizedCaseInsensitiveContains(search) } }
        if let f = filterStatus { r = r.filter { $0.status == f } }
        return r.sorted { $0.modifiedDate > $1.modifiedDate }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Pipeline").font(.caption).foregroundColor(.secondary)
                        Text(store.estimates.reduce(0) { $0 + $1.calculationResult.totalSell }.currency).font(.headline).fontWeight(.bold)
                    }
                    Spacer()
                    VStack { Text("\(store.estimates.filter { $0.status == .approved }.count)").font(.headline).foregroundColor(.green); Text("Approved").font(.caption2).foregroundColor(.secondary) }
                    Spacer()
                    VStack { Text("\(store.estimates.filter { $0.status == .draft }.count)").font(.headline).foregroundColor(.orange); Text("Drafts").font(.caption2).foregroundColor(.secondary) }
                    Spacer()
                    VStack { Text("\(store.estimates.count)").font(.headline); Text("Total").font(.caption2).foregroundColor(.secondary) }
                }
                .padding().background(Color(.systemGray6))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        EChip("All", filterStatus == nil) { filterStatus = nil }
                        ForEach(EstimateStatus.allCases, id: \.self) { s in
                            EChip(s.rawValue, filterStatus == s) { filterStatus = filterStatus == s ? nil : s }
                        }
                    }
                    .padding(.horizontal).padding(.vertical, 6)
                }
                .background(Color(.systemGray6))

                if filtered.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 50)).foregroundColor(.blue.opacity(0.5))
                        Text("No Estimates").font(.title2).fontWeight(.semibold)
                        Text("Tap + to create your first estimate").foregroundColor(.secondary)
                        Button("New Estimate") { showNew = true }.buttonStyle(.borderedProminent)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(filtered) { est in
                            NavigationLink(destination: EstimateDetail(estimate: est, store: store)) {
                                EstimateRow(estimate: est)
                            }
                        }
                        .onDelete { idx in idx.forEach { store.deleteEstimate(filtered[$0]) } }
                    }
                }
            }
            .navigationTitle("Estimates")
            .searchable(text: $search, prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gear") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showNew) { WizardView(store: store) }
            .sheet(isPresented: $showSettings) { EstSettingsView(store: store) }
        }
    }
}

struct EstimateRow: View {
    let estimate: Estimate
    var statusColor: Color {
        switch estimate.status {
        case .draft: return .gray; case .review: return .orange; case .sent: return .blue
        case .approved: return .green; case .lost: return .red; case .archived: return .gray
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(estimate.estimateNumber).font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(estimate.status.rawValue).font(.caption2).fontWeight(.semibold)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(statusColor.opacity(0.15)).foregroundColor(statusColor).cornerRadius(8)
            }
            Text(estimate.projectName).font(.headline)
            Text(estimate.clientName).font(.subheadline).foregroundColor(.secondary)
            HStack {
                Image(systemName: estimate.projectType.icon).font(.caption).foregroundColor(.blue)
                Text(estimate.projectType.rawValue).font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(estimate.calculationResult.totalSell.currency).font(.subheadline).fontWeight(.semibold).foregroundColor(.blue)
            }
        }
        .padding(.vertical, 4)
    }
}

struct WizardView: View {
    var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var step = 1
    @State private var est = Estimate()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    ForEach(1...7, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2).fill(i <= step ? Color.blue : Color(.systemGray4)).frame(height: 4)
                    }
                }
                .padding(.horizontal).padding(.top, 8)
                Text("Step \(step) of 7").font(.caption).foregroundColor(.secondary).padding(.top, 4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch step {
                        case 1: S1(est: $est, store: store)
                        case 2: S2(est: $est)
                        case 3: S3(est: $est)
                        case 4: S4(est: $est)
                        case 5: S5(est: $est)
                        case 6: S6(est: $est)
                        case 7: S7(est: $est)
                        default: EmptyView()
                        }
                    }.padding()
                }
                HStack {
                    if step > 1 { Button("Back") { step -= 1 }.buttonStyle(.bordered) }
                    Spacer()
                    if step < 7 {
                        Button("Next") {
                            if step == 6 { est.calculationResult = store.calculateEstimate(est) }
                            step += 1
                        }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Save") { store.addEstimate(est); dismiss() }.buttonStyle(.borderedProminent)
                    }
                }.padding()
            }
            .navigationTitle(["","Project Info","Project Type","Dimensions","Conditions","Labor","Pricing","Summary"][step])
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct S1: View {
    @Binding var est: Estimate
    var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SHeader("Project Information", "doc.text")
            EField("Project") {
                Picker("", selection: $est.projectName) {
                    Text("Select Project").tag("")
                    ForEach(store.projectNames, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu)
            }
            EField("Project Name (custom)") { TextField("Or enter custom name", text: $est.projectName) }
            EField("Client Name") { TextField("Client name", text: $est.clientName) }
            EField("Site Location") { TextField("Site location", text: $est.siteLocation) }
            EField("Estimator") { TextField("Estimator", text: $est.estimatorName) }
            EField("Company") {
                Picker("", selection: $est.company) {
                    Text("Blair Ventures").tag("Blair Ventures")
                    Text("Integral Containment Systems").tag("Integral Containment Systems")
                }.pickerStyle(.segmented)
            }
            EField("Scope") { TextField("Scope summary", text: $est.scopeSummary, axis: .vertical).lineLimit(3) }
            EField("Notes") { TextField("Notes", text: $est.projectNotes, axis: .vertical).lineLimit(3) }
        }
    }
}

struct S2: View {
    @Binding var est: Estimate
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SHeader("Select Project Type", "square.grid.2x2")
            ForEach(ProjectType.allCases, id: \.self) { t in
                Button { est.projectType = t } label: {
                    HStack {
                        Image(systemName: t.icon).frame(width: 30).foregroundColor(est.projectType == t ? .white : .blue)
                        Text(t.rawValue).foregroundColor(est.projectType == t ? .white : .primary)
                        Spacer()
                        if est.projectType == t { Image(systemName: "checkmark.circle.fill").foregroundColor(.white) }
                    }
                    .padding().background(est.projectType == t ? Color.blue : Color(.systemGray6)).cornerRadius(10)
                }
            }
        }
    }
}

struct S3: View {
    @Binding var est: Estimate
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SHeader("Dimensions", "ruler")
            DField("Length (ft)", $est.dimensions.length)
            DField("Width (ft)", $est.dimensions.width)
            DField("Height (ft)", $est.dimensions.height)
            DField("Roof Area (sq ft)", $est.dimensions.roofArea)
            EField("Levels") { Stepper("\(est.dimensions.numberOfLevels)", value: $est.dimensions.numberOfLevels, in: 1...20) }
            EField("Access Points") { Stepper("\(est.dimensions.accessPoints)", value: $est.dimensions.accessPoints, in: 1...20) }
            EField("Duration (days)") { Stepper("\(est.dimensions.duration) days", value: $est.dimensions.duration, in: 1...365) }
            if est.dimensions.length > 0 && est.dimensions.width > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Calculated Areas").font(.headline)
                    CRow(label: "Wall Area", value: est.dimensions.wallArea.sqft)
                    CRow(label: "Floor Area", value: est.dimensions.floorArea.sqft)
                    CRow(label: "Total Surface", value: est.dimensions.totalSurfaceArea.sqft)
                    CRow(label: "Perimeter", value: est.dimensions.perimeterLength.lnft)
                }
                .padding().background(Color.blue.opacity(0.06)).cornerRadius(10)
            }
        }
    }
}

struct S4: View {
    @Binding var est: Estimate
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SHeader("Site Conditions", "thermometer.sun")
            EField("Indoor / Outdoor") {
                Picker("", selection: $est.dimensions.indoorOutdoor) {
                    Text("Indoor").tag("Indoor"); Text("Outdoor").tag("Outdoor")
                }.pickerStyle(.segmented)
            }
            EField("Wind Exposure") {
                Picker("", selection: $est.dimensions.windExposure) {
                    Text("Sheltered").tag("Sheltered"); Text("Moderate").tag("Moderate"); Text("Exposed").tag("Exposed")
                }.pickerStyle(.segmented)
            }
            EField("Geometry Complexity") {
                VStack {
                    Slider(value: $est.dimensions.irregularGeometryFactor, in: 1.0...2.0, step: 0.05)
                    HStack {
                        Text("Simple").font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "×%.2f", est.dimensions.irregularGeometryFactor)).font(.caption).fontWeight(.semibold)
                        Spacer()
                        Text("Complex").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            EField("Penetrations") { Stepper("\(est.dimensions.complexPenetrations)", value: $est.dimensions.complexPenetrations, in: 0...50) }
        }
    }
}

struct S5: View {
    @Binding var est: Estimate
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SHeader("Labor & Equipment", "person.2.fill")
            DField("Foreman Rate ($/hr)", $est.laborConfig.foremanRate)
            DField("Labor Rate ($/hr)", $est.laborConfig.laborRate)
            EField("Crew Size") { Stepper("\(est.laborConfig.crewSize) workers", value: $est.laborConfig.crewSize, in: 1...20) }
            EField("Shift Length") { Stepper(String(format: "%.0f hrs", est.laborConfig.shiftHours), value: $est.laborConfig.shiftHours, in: 4...16, step: 1) }
            EField("Site Complexity") {
                Picker("", selection: $est.laborConfig.complexityFactor) {
                    Text("Easy ×1.0").tag(1.0); Text("Normal ×1.15").tag(1.15); Text("Hard ×1.35").tag(1.35); Text("Very Hard ×1.6").tag(1.6)
                }.pickerStyle(.menu)
            }
            EField("Night Shift") {
                Toggle("Apply Premium (×1.15)", isOn: Binding(
                    get: { est.laborConfig.nightShiftFactor > 1.0 },
                    set: { est.laborConfig.nightShiftFactor = $0 ? 1.15 : 1.0 }
                ))
            }
            DField("Mob / Demob Hours", $est.laborConfig.mobDemobHours)
        }
    }
}

struct S6: View {
    @Binding var est: Estimate
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SHeader("Pricing & Markup", "dollarsign.circle")
            PctField("Overhead %", value: $est.pricingConfig.overheadPercent)
            PctField("Profit %", value: $est.pricingConfig.profitPercent)
            PctField("Contingency %", value: $est.pricingConfig.contingencyPercent)
            PctField("Waste %", value: $est.pricingConfig.wastePercent)
            EField("Rush Factor") {
                Picker("", selection: $est.pricingConfig.rushFactor) {
                    Text("Normal ×1.0").tag(1.0); Text("Rush ×1.15").tag(1.15); Text("Urgent ×1.30").tag(1.30)
                }.pickerStyle(.segmented)
            }
            EField("Remote Factor") {
                Picker("", selection: $est.pricingConfig.remoteLocationFactor) {
                    Text("Local ×1.0").tag(1.0); Text("Remote ×1.15").tag(1.15); Text("Far ×1.30").tag(1.30)
                }.pickerStyle(.segmented)
            }
            DField("Minimum Charge ($)", $est.pricingConfig.minimumCharge)
            Toggle("Apply Tax (\(String(format: "%.1f", est.pricingConfig.taxPercent))%)", isOn: $est.pricingConfig.applyTax)
        }
    }
}

struct S7: View {
    @Binding var est: Estimate
    var r: CalculationResult { est.calculationResult }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SHeader("Summary", "checkmark.seal")
            VStack(alignment: .leading, spacing: 4) {
                Text(est.projectName).font(.title3).fontWeight(.bold)
                Text(est.clientName).foregroundColor(.secondary)
                HStack { Image(systemName: est.projectType.icon).foregroundColor(.blue); Text(est.projectType.rawValue).font(.caption) }
            }
            .padding().background(Color(.systemGray6)).cornerRadius(10)
            VStack(spacing: 0) {
                PRow(label: "Materials", value: r.materialSubtotal); PRow(label: "Labor", value: r.laborSubtotal); PRow(label: "Equipment", value: r.equipmentSubtotal)
                Divider()
                PRow(label: "Waste", value: r.wasteAllowance); PRow(label: "Contingency", value: r.contingency); PRow(label: "Overhead", value: r.overhead); PRow(label: "Profit", value: r.profit)
                if r.tax > 0 { PRow(label: "Tax", value: r.tax) }
                Divider()
                HStack { Text("TOTAL SELL").fontWeight(.bold); Spacer(); Text(r.totalSell.currency).font(.title3).fontWeight(.bold).foregroundColor(.blue) }.padding()
                HStack { Text("Gross Margin").font(.caption).foregroundColor(.secondary); Spacer(); Text(String(format: "%.1f%%", r.grossMargin)).font(.caption).foregroundColor(.green) }.padding(.horizontal).padding(.bottom, 8)
            }
            .background(Color(.systemBackground)).cornerRadius(10).shadow(color: .black.opacity(0.05), radius: 4)
            VStack(alignment: .leading, spacing: 6) {
                Text("Labor").font(.headline)
                HStack { Text("Hours").foregroundColor(.secondary); Spacer(); Text(String(format: "%.1f hrs", r.estimatedLaborHours)) }
                HStack { Text("Crew Days").foregroundColor(.secondary); Spacer(); Text(String(format: "%.1f days", r.crewDays)) }
            }
            .font(.subheadline).padding().background(Color(.systemGray6)).cornerRadius(10)
            EField("Status") {
                Picker("", selection: $est.status) {
                    ForEach(EstimateStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
            }
        }
    }
}

struct EstimateDetail: View {
    @State var estimate: Estimate
    var store: AppStore
    @State private var showLines = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(estimate.estimateNumber).font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Text(estimate.status.rawValue).font(.caption2).fontWeight(.semibold).padding(.horizontal, 8).padding(.vertical, 3).background(Color.blue.opacity(0.15)).foregroundColor(.blue).cornerRadius(8)
                    }
                    Text(estimate.projectName).font(.title2).fontWeight(.bold)
                    Text(estimate.clientName).foregroundColor(.secondary)
                }
                .padding().background(Color(.systemGray6)).cornerRadius(12)

                HStack {
                    VStack(alignment: .leading) {
                        Text("Total Sell").font(.caption).foregroundColor(.secondary)
                        Text(estimate.calculationResult.totalSell.currency).font(.largeTitle).fontWeight(.bold).foregroundColor(.blue)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("Gross Margin").font(.caption).foregroundColor(.secondary)
                        Text(String(format: "%.1f%%", estimate.calculationResult.grossMargin)).font(.title2).fontWeight(.semibold).foregroundColor(.green)
                    }
                }
                .padding().background(Color.blue.opacity(0.06)).cornerRadius(12)

                VStack(spacing: 0) {
                    Text("Breakdown").font(.headline).padding()
                    PRow(label: "Materials", value: estimate.calculationResult.materialSubtotal)
                    PRow(label: "Labor", value: estimate.calculationResult.laborSubtotal)
                    PRow(label: "Equipment", value: estimate.calculationResult.equipmentSubtotal)
                    Divider()
                    PRow(label: "Waste", value: estimate.calculationResult.wasteAllowance)
                    PRow(label: "Contingency", value: estimate.calculationResult.contingency)
                    PRow(label: "Overhead", value: estimate.calculationResult.overhead)
                    PRow(label: "Profit", value: estimate.calculationResult.profit)
                    if estimate.calculationResult.tax > 0 { PRow(label: "Tax", value: estimate.calculationResult.tax) }
                }
                .background(Color(.systemBackground)).cornerRadius(12).shadow(color: .black.opacity(0.05), radius: 4)

                Button { showLines = true } label: {
                    Label("Line Items (\(estimate.calculationResult.lineItems.count))", systemImage: "list.bullet.rectangle")
                        .frame(maxWidth: .infinity).padding().background(Color(.systemGray6)).cornerRadius(10)
                }

                HStack(spacing: 12) {
                    Button { store.duplicateEstimate(estimate) } label: {
                        Label("Duplicate", systemImage: "doc.on.doc").frame(maxWidth: .infinity).padding().background(Color(.systemGray6)).cornerRadius(10)
                    }
                    Picker("", selection: $estimate.status) {
                        ForEach(EstimateStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: estimate.status) { _, _ in store.updateEstimate(estimate) }
                }
            }.padding()
        }
        .navigationTitle(estimate.projectName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLines) { EstLineItems(items: estimate.calculationResult.lineItems) }
    }
}

struct EstLineItems: View {
    let items: [EstimateLineItem]
    @Environment(\.dismiss) var dismiss
    var grouped: [String: [EstimateLineItem]] { Dictionary(grouping: items) { $0.category } }
    var body: some View {
        NavigationView {
            List {
                ForEach(grouped.keys.sorted(), id: \.self) { cat in
                    Section(cat) {
                        ForEach(grouped[cat] ?? []) { item in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.description).font(.subheadline)
                                    Text("\(item.quantity.clean) \(item.unit) × \(item.unitCost.currency)").font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(item.total.currency).fontWeight(.semibold)
                            }
                        }
                        let sub = (grouped[cat] ?? []).reduce(0) { $0 + $1.total }
                        HStack { Text("Subtotal").fontWeight(.semibold); Spacer(); Text(sub.currency).fontWeight(.semibold).foregroundColor(.blue) }
                    }
                }
            }
            .navigationTitle("Line Items")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

struct EstSettingsView: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationView {
            Form {
                Section("Company") {
                    TextField("Name", text: $store.companySettings.companyName)
                    TextField("Contact", text: $store.companySettings.contactName)
                    TextField("Phone", text: $store.companySettings.phone)
                    TextField("Email", text: $store.companySettings.email)
                }
                Section("Numbering") {
                    TextField("Prefix", text: $store.companySettings.estimatePrefix)
                    HStack { Text("Next #"); Spacer(); Text("\(store.companySettings.nextEstimateNumber)") }
                }
                Section("Markup Defaults") {
                    PctField("Overhead %", value: $store.companySettings.defaultOverhead)
                    PctField("Profit %", value: $store.companySettings.defaultProfit)
                    PctField("Contingency %", value: $store.companySettings.defaultContingency)
                    PctField("Waste %", value: $store.companySettings.defaultWaste)
                }
                Section("Tax") {
                    Toggle("Apply Tax", isOn: $store.companySettings.applyTax)
                    PctField("Rate %", value: $store.companySettings.taxRate)
                }
                Section("Databases") {
                    NavigationLink("Materials (\(store.materials.count))") { EstMatDB(store: store) }
                    NavigationLink("Equipment (\(store.equipment.count))") { EstEqDB(store: store) }
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Save") { store.save(); dismiss() } } }
        }
    }
}

struct EstMatDB: View {
    @Bindable var store: AppStore
    @State private var showAdd = false
    var body: some View {
        List {
            ForEach(MaterialCategory.allCases, id: \.self) { cat in
                let items = store.materials.filter { $0.category == cat }
                if !items.isEmpty {
                    Section(cat.rawValue) {
                        ForEach(items) { m in
                            HStack {
                                VStack(alignment: .leading) { Text(m.name).font(.subheadline); Text("\(m.unitCost.currency) / \(m.unit.rawValue)").font(.caption).foregroundColor(.secondary) }
                                Spacer()
                            }
                        }
                        .onDelete { idx in
                            let ids = idx.map { items[$0].id }
                            store.materials.removeAll { ids.contains($0.id) }
                            store.save()
                        }
                    }
                }
            }
        }
        .navigationTitle("Materials")
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { showAdd = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $showAdd) { EstAddMat(store: store) }
    }
}

struct EstAddMat: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var name = ""; @State private var cat = MaterialCategory.shrinkWrap
    @State private var unit = UnitType.roll; @State private var cost = ""; @State private var coverage = ""; @State private var waste = "10"
    var body: some View {
        NavigationView {
            Form {
                TextField("Name", text: $name)
                Picker("Category", selection: $cat) { ForEach(MaterialCategory.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Picker("Unit", selection: $unit) { ForEach(UnitType.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                TextField("Unit Cost ($)", text: $cost).keyboardType(.decimalPad)
                TextField("Coverage Rate", text: $coverage).keyboardType(.decimalPad)
                TextField("Waste Factor %", text: $waste).keyboardType(.decimalPad)
            }
            .navigationTitle("Add Material")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        store.materials.append(MaterialItem(name: name, category: cat, unit: unit, unitCost: Double(cost) ?? 0, coverageRate: Double(coverage) ?? 1, wasteFactor: Double(waste) ?? 10))
                        store.save(); dismiss()
                    }.disabled(name.isEmpty)
                }
            }
        }
    }
}

struct EstEqDB: View {
    @Bindable var store: AppStore
    @State private var showAdd = false
    var body: some View {
        List {
            ForEach(store.equipment) { e in
                VStack(alignment: .leading, spacing: 4) {
                    Text(e.name).font(.subheadline).fontWeight(.semibold)
                    HStack { Text("D: \(e.dailyRate.currency)").font(.caption).foregroundColor(.secondary); Text("W: \(e.weeklyRate.currency)").font(.caption).foregroundColor(.secondary); Text("M: \(e.monthlyRate.currency)").font(.caption).foregroundColor(.secondary) }
                }
            }
            .onDelete { store.equipment.remove(atOffsets: $0); store.save() }
        }
        .navigationTitle("Equipment")
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { showAdd = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $showAdd) { EstAddEq(store: store) }
    }
}

struct EstAddEq: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var name = ""; @State private var daily = ""; @State private var weekly = ""; @State private var monthly = ""
    var body: some View {
        NavigationView {
            Form {
                TextField("Name", text: $name)
                TextField("Daily Rate ($)", text: $daily).keyboardType(.decimalPad)
                TextField("Weekly Rate ($)", text: $weekly).keyboardType(.decimalPad)
                TextField("Monthly Rate ($)", text: $monthly).keyboardType(.decimalPad)
            }
            .navigationTitle("Add Equipment")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        store.equipment.append(EquipmentItem(name: name, dailyRate: Double(daily) ?? 0, weeklyRate: Double(weekly) ?? 0, monthlyRate: Double(monthly) ?? 0))
                        store.save(); dismiss()
                    }.disabled(name.isEmpty)
                }
            }
        }
    }
}

// MARK: - Shared Components

struct SHeader: View {
    let title: String; let icon: String
    init(_ title: String, _ icon: String) { self.title = title; self.icon = icon }
    var body: some View { HStack { Image(systemName: icon).foregroundColor(.blue); Text(title).font(.title3).fontWeight(.semibold) } }
}

struct EField<C: View>: View {
    let label: String; let content: () -> C
    init(_ label: String, @ViewBuilder content: @escaping () -> C) { self.label = label; self.content = content }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
            content().padding(10).background(Color(.systemGray6)).cornerRadius(8)
        }
    }
}

struct DField: View {
    let label: String; @Binding var value: Double
    init(_ label: String, _ value: Binding<Double>) { self.label = label; self._value = value }
    var body: some View { EField(label) { TextField("0", value: $value, format: .number).keyboardType(.decimalPad) } }
}

struct PctField: View {
    let label: String; @Binding var value: Double
    init(_ label: String, value: Binding<Double>) { self.label = label; self._value = value }
    var body: some View {
        HStack {
            Text(label).font(.subheadline); Spacer()
            TextField("0", value: $value, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 60)
            Text("%").foregroundColor(.secondary)
        }
    }
}

struct PRow: View {
    let label: String; let value: Double
    var body: some View {
        HStack { Text(label).font(.subheadline).foregroundColor(.secondary); Spacer(); Text(value.currency).font(.subheadline) }
        .padding(.horizontal).padding(.vertical, 6)
    }
}

struct CRow: View {
    let label: String; let value: String
    var body: some View { HStack { Text(label).font(.caption).foregroundColor(.secondary); Spacer(); Text(value).font(.caption).fontWeight(.semibold) } }
}

struct EChip: View {
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

extension Double {
    var currency: String {
        let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = "CAD"; f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: self)) ?? "$0.00"
    }
    var sqft: String { String(format: "%.0f sq ft", self) }
    var lnft: String { String(format: "%.0f ln ft", self) }
    var cuft: String { String(format: "%.0f cu ft", self) }
    var clean: String { truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", self) : String(format: "%.2f", self) }
}
