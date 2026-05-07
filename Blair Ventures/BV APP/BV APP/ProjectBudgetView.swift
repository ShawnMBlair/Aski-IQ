// ProjectBudgetView.swift
// Aski IQ – Project Budget / WBS View
// Full budget breakdown: original contract → CO adjustments → revised budget
//                        budgeted vs committed (POs) vs actual (labour + invoiced)

import SwiftUI

// MARK: - Main View

struct ProjectBudgetView: View {
    let project: Project
    @EnvironmentObject var store: AppStore
    @State private var showSetup = false

    private var budget: ProjectBudget? { store.budget(for: project.id) }
    private var laborCost:       Decimal { store.laborCost(for: project.id) }
    private var committedMat:    Decimal { store.committedMaterialCost(for: project.id) }
    private var approvedCOs:     Decimal { store.approvedCOValue(for: project.id) }
    private var totalActual:     Decimal { laborCost + committedMat }
    private var revisedContract: Decimal {
        (budget?.originalContractValue ?? project.contractValue ?? project.estimatedBudget ?? 0) + approvedCOs
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                BudgetSummaryCard(
                    project: project,
                    budget: budget,
                    laborCost: laborCost,
                    committedMat: committedMat,
                    approvedCOs: approvedCOs,
                    revisedContract: revisedContract
                )
                BudgetCOSection(project: project, approvedCOs: approvedCOs)
                BudgetLinesSection(project: project, budget: budget, laborCost: laborCost)
                BudgetMaterialSection(project: project, committedMat: committedMat)
                Spacer(minLength: 32)
            }
            .padding(.top)
        }
        .navigationTitle("Budget")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if store.currentUserRole.canManageBudget {
                    Button(budget == nil ? "Set Up Budget" : "Edit Budget") {
                        showSetup = true
                    }
                }
            }
        }
        .sheet(isPresented: $showSetup) {
            BudgetSetupSheet(project: project, existing: budget)
        }
    }
}

// MARK: - Summary Card

private struct BudgetSummaryCard: View {
    let project: Project
    let budget: ProjectBudget?
    let laborCost: Decimal
    let committedMat: Decimal
    let approvedCOs: Decimal
    let revisedContract: Decimal

    private var totalActual: Decimal { laborCost + committedMat }
    private var utilization: Double {
        guard revisedContract > 0 else { return 0 }
        return min(NSDecimalNumber(decimal: totalActual / revisedContract).doubleValue, 1.5)
    }
    private var utilizationPct: Int { Int(min(utilization, 1.0) * 100) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(project.name).font(.headline)
            BudgetTopStats(
                revisedContract: revisedContract,
                totalActual: totalActual,
                approvedCOs: approvedCOs
            )
            if revisedContract > 0 {
                BudgetUtilBar(utilization: utilization, utilizationPct: utilizationPct)
            }
            if budget == nil {
                Label("No budget set up yet. Tap 'Set Up Budget' to get started.",
                      systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundColor(.orange)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .padding(.horizontal)
    }
}

private struct BudgetTopStats: View {
    let revisedContract: Decimal
    let totalActual: Decimal
    let approvedCOs: Decimal
    var body: some View {
        HStack(spacing: 0) {
            BudgetStat(label: "Revised Budget",  value: revisedContract.currencyString, color: .blue)
            Divider().frame(height: 44)
            BudgetStat(label: "Actual + Committed", value: totalActual.currencyString,
                       color: totalActual > revisedContract ? .red : .primary)
            if approvedCOs != 0 {
                Divider().frame(height: 44)
                BudgetStat(label: "CO Adjustments",
                           value: (approvedCOs >= 0 ? "+" : "") + approvedCOs.currencyString,
                           color: approvedCOs >= 0 ? .orange : .green)
            }
        }
    }
}

private struct BudgetUtilBar: View {
    let utilization: Double
    let utilizationPct: Int
    private var barColor: Color {
        if utilizationPct < 70 { return .green }
        if utilizationPct < 90 { return .orange }
        return .red
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Budget Utilization").font(.caption).foregroundColor(.secondary)
                Spacer()
                Text("\(utilizationPct)%").font(.caption).bold().foregroundColor(barColor)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6).fill(Color(.systemGray5)).frame(height: 12)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(barColor)
                        .frame(width: max(geo.size.width * CGFloat(min(utilization, 1.0)), 6), height: 12)
                        .animation(.easeOut(duration: 0.4), value: utilization)
                }
            }
            .frame(height: 12)
        }
    }
}

// MARK: - Change Order Section

private struct BudgetCOSection: View {
    @EnvironmentObject var store: AppStore
    let project: Project
    let approvedCOs: Decimal

    private var cos: [ChangeOrder] {
        store.changeOrders(for: project.id).filter { $0.status == .approved }
    }

    var body: some View {
        if !cos.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Approved Change Orders", count: cos.count)
                VStack(spacing: 0) {
                    ForEach(cos) { co in
                        NavigationLink(destination: ChangeOrderDetailView(changeOrder: co)) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(co.number).font(.caption2).foregroundColor(.secondary)
                                    Text(co.title).font(.subheadline)
                                }
                                Spacer()
                                Text((co.effectiveCostImpact >= 0 ? "+" : "") + co.effectiveCostImpact.currencyString)
                                    .font(.subheadline).bold()
                                    .foregroundColor(co.effectiveCostImpact >= 0 ? .orange : .green)
                            }
                            .padding(.horizontal).padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        if co.id != cos.last?.id { Divider().padding(.leading) }
                    }
                    Divider()
                    HStack {
                        Text("Net CO Impact").font(.subheadline).bold()
                        Spacer()
                        Text((approvedCOs >= 0 ? "+" : "") + approvedCOs.currencyString)
                            .font(.subheadline).bold()
                            .foregroundColor(approvedCOs >= 0 ? .orange : .green)
                    }
                    .padding(.horizontal).padding(.vertical, 10)
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12).padding(.horizontal)
            }
        }
    }
}

// MARK: - Budget Lines Section

private struct BudgetLinesSection: View {
    @EnvironmentObject var store: AppStore
    let project: Project
    let budget: ProjectBudget?
    let laborCost: Decimal

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Cost Code Budget", count: budget?.lines.count ?? 0)
            if let budget, !budget.lines.isEmpty {
                BudgetLinesTable(project: project, budget: budget, laborCost: laborCost)
            } else {
                EmptyCard(message: "Set up budget lines to track spending per cost code.")
            }
        }
    }
}

private struct BudgetLinesTable: View {
    @EnvironmentObject var store: AppStore
    let project: Project
    let budget: ProjectBudget
    let laborCost: Decimal

    private var hoursByCostCode: [(code: String, regular: Decimal, overtime: Decimal)] {
        store.hoursByCostCode(for: project.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            BudgetLinesTableHeader()
            ForEach(budget.lines.sorted { $0.sortOrder < $1.sortOrder }) { line in
                let actual = actualLabour(for: line.costCode)
                let variance = line.budgetedLabour - actual
                BudgetLineRow(line: line, actualLabour: actual, variance: variance)
                if line.id != budget.lines.last?.id { Divider().padding(.leading) }
            }
            Divider()
            BudgetLinesTotalRow(budget: budget, totalActual: laborCost)
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12).padding(.horizontal)
    }

    private func actualLabour(for code: String) -> Decimal {
        guard let match = hoursByCostCode.first(where: { $0.code == code }) else { return 0 }
        let emp = store.employees
        let totalHrs = match.regular + match.overtime
        // Estimate labour $ as average rate × hours (simplified without code-level rate split)
        guard !emp.isEmpty else { return 0 }
        let avgRate = emp.compactMap { $0.regularRate }.reduce(0, +) / Decimal(emp.count)
        return totalHrs * avgRate
    }
}

private struct BudgetLinesTableHeader: View {
    var body: some View {
        HStack {
            Text("Code / Description")
                .font(.caption2).bold().foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Budgeted").font(.caption2).bold().foregroundColor(.secondary).frame(width: 72, alignment: .trailing)
            Text("Actual").font(.caption2).bold().foregroundColor(.secondary).frame(width: 64, alignment: .trailing)
            Text("Var").font(.caption2).bold().foregroundColor(.secondary).frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(Color(.systemGray6))
    }
}

private struct BudgetLineRow: View {
    let line: ProjectBudgetLine
    let actualLabour: Decimal
    let variance: Decimal

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(line.costCode).font(.caption).bold()
                Text(line.description).font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(line.totalBudgeted.currencyString).font(.caption).frame(width: 72, alignment: .trailing)
            Text(actualLabour > 0 ? actualLabour.currencyString : "—")
                .font(.caption).frame(width: 64, alignment: .trailing)
            if actualLabour > 0 {
                Text((variance >= 0 ? "+" : "") + variance.currencyString)
                    .font(.caption2).bold()
                    .foregroundColor(variance >= 0 ? .green : .red)
                    .frame(width: 56, alignment: .trailing)
            } else {
                Text("—").font(.caption2).foregroundColor(.secondary).frame(width: 56, alignment: .trailing)
            }
        }
        .padding(.horizontal).padding(.vertical, 9)
    }
}

private struct BudgetLinesTotalRow: View {
    let budget: ProjectBudget
    let totalActual: Decimal
    private var variance: Decimal { budget.totalLinesBudgeted - totalActual }
    var body: some View {
        HStack {
            Text("Total").font(.subheadline).bold()
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(budget.totalLinesBudgeted.currencyString).font(.caption).bold().frame(width: 72, alignment: .trailing)
            Text(totalActual > 0 ? totalActual.currencyString : "—")
                .font(.caption).bold().frame(width: 64, alignment: .trailing)
            Text(totalActual > 0 ? (variance >= 0 ? "+" : "") + variance.currencyString : "—")
                .font(.caption2).bold()
                .foregroundColor(variance >= 0 ? .green : .red)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal).padding(.vertical, 10)
    }
}

// MARK: - Material / Committed Section

private struct BudgetMaterialSection: View {
    @EnvironmentObject var store: AppStore
    let project: Project
    let committedMat: Decimal

    private var pos: [PurchaseOrder] {
        store.purchaseOrders
            .filter { $0.projectID == project.id && $0.status != .draft && $0.status != .cancelled }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Committed Materials", count: pos.count)
            if pos.isEmpty {
                EmptyCard(message: "No purchase orders committed to this project.")
            } else {
                VStack(spacing: 0) {
                    ForEach(pos) { po in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(po.poNumber).font(.caption2).foregroundColor(.secondary)
                                Text(po.supplierName).font(.subheadline)
                                POStatusBadgeInline(status: po.status)
                            }
                            Spacer()
                            Text(po.total.currencyString).font(.subheadline).bold()
                        }
                        .padding(.horizontal).padding(.vertical, 10)
                        if po.id != pos.last?.id { Divider().padding(.leading) }
                    }
                    Divider()
                    HStack {
                        Text("Total Committed").font(.subheadline).bold()
                        Spacer()
                        Text(committedMat.currencyString).font(.subheadline).bold()
                    }
                    .padding(.horizontal).padding(.vertical, 10)
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12).padding(.horizontal)
            }
        }
    }
}

private struct POStatusBadgeInline: View {
    let status: POStatus
    var body: some View {
        Text(status.displayName)
            .font(.caption2).bold()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.blue.opacity(0.1))
            .foregroundColor(.blue)
            .cornerRadius(4)
    }
}

// MARK: - Budget Stat Cell

struct BudgetStat: View {
    let label: String; let value: String; let color: Color
    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(.subheadline).bold().foregroundColor(color).minimumScaleFactor(0.7).lineLimit(1)
            Text(label).font(.caption2).foregroundColor(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

// MARK: - Budget Setup Sheet

struct BudgetSetupSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let project: Project
    var existing: ProjectBudget?

    @State private var contractValue: String = ""
    @State private var contingency: String = ""
    @State private var lines: [ProjectBudgetLine] = []
    @State private var showAddLine = false

    var body: some View {
        NavigationStack {
            BudgetSetupForm(
                contractValue: $contractValue,
                contingency: $contingency,
                lines: $lines,
                showAddLine: $showAddLine
            )
            .navigationTitle(existing == nil ? "Set Up Budget" : "Edit Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading)  { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }.bold()
                }
            }
        }
        .onAppear { populate() }
    }

    private func populate() {
        if let b = existing {
            contractValue = "\(b.originalContractValue)"
            contingency   = "\(b.contingencyAmount)"
            lines         = b.lines
        } else {
            // Pre-populate from estimate if one exists
            let draft = store.budgetFromEstimate(for: project)
            contractValue = "\(draft.originalContractValue)"
            contingency   = "\(draft.contingencyAmount)"
            lines         = draft.lines
        }
    }

    private func save() {
        var budget = existing ?? ProjectBudget(projectID: project.id)
        budget.originalContractValue = Decimal(string: contractValue) ?? 0
        budget.contingencyAmount     = Decimal(string: contingency) ?? 0
        budget.lines                 = lines
        store.upsertBudget(budget)
        dismiss()
    }
}

private struct BudgetSetupForm: View {
    @Binding var contractValue: String
    @Binding var contingency: String
    @Binding var lines: [ProjectBudgetLine]
    @Binding var showAddLine: Bool

    var body: some View {
        Form {
            BudgetSetupContractSection(contractValue: $contractValue, contingency: $contingency)
            BudgetSetupLinesSection(lines: $lines, showAddLine: $showAddLine)
        }
    }
}

private struct BudgetSetupContractSection: View {
    @Binding var contractValue: String
    @Binding var contingency: String
    var body: some View {
        Section("Contract") {
            HStack {
                Text("Original Contract Value")
                Spacer()
                TextField("0.00", text: $contractValue)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 130)
            }
            HStack {
                Text("Contingency ($)")
                Spacer()
                TextField("0.00", text: $contingency)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 130)
            }
        }
    }
}

private struct BudgetSetupLinesSection: View {
    @Binding var lines: [ProjectBudgetLine]
    @Binding var showAddLine: Bool

    var body: some View {
        Section("Cost Code Lines") {
            ForEach(lines) { line in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(line.costCode).font(.subheadline).bold()
                        Spacer()
                        Text(line.totalBudgeted.currencyString).font(.subheadline)
                    }
                    Text(line.description).font(.caption).foregroundColor(.secondary)
                    HStack(spacing: 16) {
                        if line.budgetedLabour   > 0 { Text("Labour: \(line.budgetedLabour.currencyString)").font(.caption2).foregroundColor(.blue) }
                        if line.budgetedMaterial > 0 { Text("Matl: \(line.budgetedMaterial.currencyString)").font(.caption2).foregroundColor(.orange) }
                        if line.budgetedOther    > 0 { Text("Other: \(line.budgetedOther.currencyString)").font(.caption2).foregroundColor(.secondary) }
                    }
                }
                .padding(.vertical, 2)
            }
            .onDelete { indexSet in lines.remove(atOffsets: indexSet) }
            .onMove  { from, to  in lines.move(fromOffsets: from, toOffset: to) }
            Button { showAddLine = true } label: {
                Label("Add Cost Code Line", systemImage: "plus.circle")
            }
        }
        .sheet(isPresented: $showAddLine) {
            BudgetLineAddSheet { lines.append($0) }
        }
    }
}

// MARK: - Budget Line Add Sheet

private struct BudgetLineAddSheet: View {
    @Environment(\.dismiss) var dismiss
    let onAdd: (ProjectBudgetLine) -> Void

    @State private var code        = ""
    @State private var description = ""
    @State private var labour      = ""
    @State private var material    = ""
    @State private var other       = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Cost Code") {
                    TextField("Code (e.g. 03.01)", text: $code)
                    TextField("Description", text: $description)
                }
                Section("Budget Allocation ($)") {
                    HStack { Text("Labour");   Spacer(); TextField("0.00", text: $labour).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 130) }
                    HStack { Text("Material"); Spacer(); TextField("0.00", text: $material).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 130) }
                    HStack { Text("Other");    Spacer(); TextField("0.00", text: $other).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 130) }
                }
                let total = (Decimal(string: labour) ?? 0) + (Decimal(string: material) ?? 0) + (Decimal(string: other) ?? 0)
                Section { HStack { Text("Total").bold(); Spacer(); Text(total.currencyString).bold() } }
            }
            .navigationTitle("Add Budget Line")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading)  { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") {
                        onAdd(ProjectBudgetLine(
                            costCode: code.isEmpty ? "OTHER" : code,
                            description: description,
                            budgetedLabour:   Decimal(string: labour)   ?? 0,
                            budgetedMaterial: Decimal(string: material) ?? 0,
                            budgetedOther:    Decimal(string: other)    ?? 0
                        ))
                        dismiss()
                    }
                    .bold().disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Budget Banner Row (used in ProjectDetailView commercial section)

struct ProjectBudgetBannerRow: View {
    let project: Project
    @EnvironmentObject var store: AppStore

    private var budget: ProjectBudget?  { store.budget(for: project.id) }
    private var laborCost: Decimal      { store.laborCost(for: project.id) }
    private var committedMat: Decimal   { store.committedMaterialCost(for: project.id) }
    private var approvedCOs: Decimal    { store.approvedCOValue(for: project.id) }
    private var revisedContract: Decimal {
        (budget?.originalContractValue ?? project.contractValue ?? project.estimatedBudget ?? 0) + approvedCOs
    }
    private var totalActual: Decimal { laborCost + committedMat }
    private var utilization: Double {
        guard revisedContract > 0 else { return 0 }
        return min(NSDecimalNumber(decimal: totalActual / revisedContract).doubleValue, 1.5)
    }
    private var utilizationPct: Int { Int(min(utilization, 1.0) * 100) }
    private var barColor: Color {
        if utilizationPct < 70 { return .green }
        if utilizationPct < 90 { return .orange }
        return .red
    }

    var body: some View {
        NavigationLink(destination: ProjectBudgetView(project: project)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Project Budget", systemImage: "chart.pie.fill")
                        .font(.subheadline).bold().foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                }
                HStack(spacing: 0) {
                    BudgetStat(label: "Budget",   value: revisedContract > 0 ? revisedContract.currencyString : "Not set", color: .blue)
                    Divider().frame(height: 36)
                    BudgetStat(label: "Actual",   value: totalActual > 0 ? totalActual.currencyString : "—",  color: totalActual > revisedContract ? .red : .primary)
                    if approvedCOs != 0 {
                        Divider().frame(height: 36)
                        BudgetStat(label: "COs",  value: (approvedCOs >= 0 ? "+" : "") + approvedCOs.currencyString, color: .orange)
                    }
                }
                if revisedContract > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4).fill(Color(.systemGray5)).frame(height: 8)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(barColor)
                                .frame(width: max(geo.size.width * CGFloat(min(utilization, 1.0)), 4), height: 8)
                        }
                    }
                    .frame(height: 8)
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - UserRole Extension

private extension UserRole {
    var canManageBudget: Bool {
        [.projectManager, .officeAdmin, .manager, .executive, .owner].contains(self)
    }
}
