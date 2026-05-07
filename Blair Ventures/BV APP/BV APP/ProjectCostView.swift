// ProjectCostView.swift
// Aski IQ – Project Cost Visibility for Field Roles

import SwiftUI

// MARK: - Cost helpers on AppStore

extension AppStore {

    /// Total approved + pending labour cost for a project (regular + overtime).
    func laborCost(for projectID: UUID) -> Decimal {
        timesheets(for: projectID).reduce(Decimal(0)) { total, entry in
            guard let emp = employee(id: entry.employeeID) else { return total }
            let reg = emp.regularRate ?? 0
            let ot  = emp.overtimeRate ?? (reg * Decimal(string: "1.5")!)
            return total + entry.regularHours * reg + entry.overtimeHours * ot
        }
    }

    /// Hours grouped by cost code.
    func hoursByCostCode(for projectID: UUID) -> [(code: String, regular: Decimal, overtime: Decimal)] {
        let entries = timesheets(for: projectID)
        var map: [String: (Decimal, Decimal)] = [:]
        for entry in entries {
            let key = entry.costCode ?? "Uncoded"
            let cur = map[key] ?? (0, 0)
            map[key] = (cur.0 + entry.regularHours, cur.1 + entry.overtimeHours)
        }
        return map.map { (code: $0.key, regular: $0.value.0, overtime: $0.value.1) }
            .sorted { $0.regular + $0.overtime > $1.regular + $1.overtime }
    }

    /// Labor cost per employee on a project.
    func laborCostByEmployee(for projectID: UUID) -> [(employee: Employee, hours: Decimal, cost: Decimal)] {
        let entries = timesheets(for: projectID)
        var map: [UUID: (Decimal, Decimal)] = [:]
        for entry in entries {
            let cur = map[entry.employeeID] ?? (0, 0)
            map[entry.employeeID] = (cur.0 + entry.totalHours,
                                     cur.1 + laborCost(for: entry))
        }
        return map.compactMap { empID, vals in
            guard let emp = employee(id: empID) else { return nil }
            return (employee: emp, hours: vals.0, cost: vals.1)
        }.sorted { $0.hours > $1.hours }
    }

    /// Daily hours logged over the last N calendar days.
    func dailyHours(for projectID: UUID, days: Int = 7) -> [(date: Date, hours: Decimal)] {
        let cal   = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<days).reversed().map { offset -> (Date, Decimal) in
            let day   = cal.date(byAdding: .day, value: -offset, to: today)!
            let hours = timesheets(for: projectID)
                .filter { cal.isDate($0.date, inSameDayAs: day) }
                .reduce(Decimal(0)) { $0 + $1.totalHours }
            return (day, hours)
        }
    }

    // Private helper — labor cost for a single entry
    private func laborCost(for entry: TimesheetEntry) -> Decimal {
        guard let emp = employee(id: entry.employeeID) else { return 0 }
        let reg = emp.regularRate ?? 0
        let ot  = emp.overtimeRate ?? (reg * Decimal(string: "1.5")!)
        return entry.regularHours * reg + entry.overtimeHours * ot
    }
}

// MARK: - Project Cost View

struct ProjectCostView: View {
    let project: Project
    @EnvironmentObject var store: AppStore

    /// Only office/management roles see dollar amounts.
    private var showDollars: Bool {
        !store.currentUserRole.isFieldRole
    }

    private var timesheets: [TimesheetEntry] { store.timesheets(for: project.id) }
    private var totalHours: Decimal { timesheets.reduce(0) { $0 + $1.totalHours } }
    private var laborCost:  Decimal { store.laborCost(for: project.id) }
    private var budget:     Decimal? { project.estimatedBudget ?? project.contractValue }
    private var hoursByCostCode: [(code: String, regular: Decimal, overtime: Decimal)] {
        store.hoursByCostCode(for: project.id)
    }
    private var crewCosts: [(employee: Employee, hours: Decimal, cost: Decimal)] {
        store.laborCostByEmployee(for: project.id)
    }
    private var dailyHours: [(date: Date, hours: Decimal)] {
        store.dailyHours(for: project.id, days: 7)
    }

    // Estimate linked to this project (if any)
    private var linkedEstimate: Estimate? {
        store.estimates.first { $0.projectID == project.id }
            ?? store.estimates.first { project.estimateIDs.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // MARK: Budget Overview
                budgetOverviewCard

                // MARK: Daily Hours (last 7 days)
                dailyHoursSection

                // MARK: Cost Code Breakdown
                if !hoursByCostCode.isEmpty {
                    costCodeSection
                }

                // MARK: Crew Labour
                if !crewCosts.isEmpty {
                    crewSection
                }

                // MARK: Estimate vs Actual (office/management roles only)
                if !store.currentUserRole.isFieldRole,
                   let estimate = linkedEstimate, !estimate.lineItems.isEmpty {
                    estimateVsActualSection(estimate: estimate)
                }

                Spacer(minLength: 32)
            }
            .padding(.top)
        }
        .navigationTitle(store.currentUserRole.isFieldRole ? "Project Hours" : "Project Costs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.currentUserRole.isFieldRole {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: ProjectBudgetView(project: project)) {
                        Label("Budget", systemImage: "chart.pie")
                    }
                }
            }
        }
    }

    // MARK: - Overview Card

    private var budgetOverviewCard: some View {
        VStack(alignment: .leading, spacing: 16) {

            Text(project.name)
                .font(.headline)

            // Stats row — field roles: hours only; office roles: hours + cost + budget
            HStack(spacing: 0) {
                CostStatCell(
                    value: totalHours.formatted() + " hrs",
                    label: "Hours Logged",
                    icon: "clock.fill",
                    color: .blue
                )
                if showDollars {
                    CostStatCell(
                        value: laborCost.currencyString,
                        label: "Labour Cost",
                        icon: "dollarsign.circle.fill",
                        color: .purple
                    )
                    if let b = budget {
                        CostStatCell(
                            value: b.currencyString,
                            label: "Budget",
                            icon: "chart.pie.fill",
                            color: .teal
                        )
                    }
                }
            }

            // Budget bar — office/management roles only
            if showDollars, let b = budget, b > 0 {
                let pct    = min(NSDecimalNumber(decimal: laborCost / b).doubleValue, 1.0)
                let pctInt = Int(pct * 100)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Budget Utilization")
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Text("\(pctInt)%")
                            .font(.caption).bold()
                            .foregroundColor(utilizationColor(pctInt))
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(.systemGray5))
                                .frame(height: 12)
                            RoundedRectangle(cornerRadius: 6)
                                .fill(utilizationColor(pctInt))
                                .frame(width: max(geo.size.width * CGFloat(pct), 6), height: 12)
                                .animation(.easeOut(duration: 0.4), value: pct)
                        }
                    }
                    .frame(height: 12)

                    let remaining = b - laborCost
                    HStack {
                        Label(
                            remaining > 0
                                ? "\(remaining.currencyString) remaining"
                                : "Over budget by \((laborCost - b).currencyString)",
                            systemImage: remaining > 0 ? "checkmark.circle" : "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundColor(remaining > 0 ? .secondary : .red)
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .padding(.horizontal)
    }

    // MARK: - Daily Hours Chart (last 7 days)

    private var dailyHoursSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Daily Hours — Last 7 Days")
            VStack(alignment: .leading, spacing: 12) {
                let maxH = dailyHours.map { NSDecimalNumber(decimal: $0.hours).doubleValue }.max() ?? 1

                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(dailyHours, id: \.date) { day in
                        let h = NSDecimalNumber(decimal: day.hours).doubleValue
                        let barH = maxH > 0 ? CGFloat(h / maxH) * 80 : 2
                        let isToday = Calendar.current.isDateInToday(day.date)

                        VStack(spacing: 4) {
                            if h > 0 {
                                Text(String(format: "%.0f", h))
                                    .font(.system(size: 9)).bold()
                                    .foregroundColor(.secondary)
                            }
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isToday ? Color.blue : Color.blue.opacity(0.35))
                                .frame(height: max(barH, 2))
                            Text(dayLabel(day.date))
                                .font(.system(size: 9))
                                .foregroundColor(isToday ? .blue : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 110)
                .padding(.horizontal, 4)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }

    // MARK: - Cost Code Breakdown

    private var costCodeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Hours by Cost Code", count: hoursByCostCode.count)
            VStack(spacing: 0) {
                ForEach(hoursByCostCode, id: \.code) { row in
                    let total  = row.regular + row.overtime
                    let maxH   = hoursByCostCode.map { $0.regular + $0.overtime }.max() ?? 1
                    let frac   = maxH > 0 ? CGFloat(NSDecimalNumber(decimal: total / maxH).doubleValue) : 0

                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.code)
                                .font(.subheadline).bold()
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.blue.opacity(0.25))
                                    .frame(height: 6)
                                    .overlay(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(Color.blue)
                                            .frame(width: geo.size.width * frac, height: 6)
                                    }
                            }
                            .frame(height: 6)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(total.formatted() + " hrs")
                                .font(.subheadline).bold()
                            if row.overtime > 0 {
                                Text(row.overtime.formatted() + " OT")
                                    .font(.caption2).foregroundColor(.orange)
                            }
                        }
                        .frame(width: 72)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)

                    if row.code != hoursByCostCode.last?.code {
                        Divider().padding(.leading)
                    }
                }
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }

    // MARK: - Crew Labour Section

    private var crewSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(
                title: showDollars ? "Labour Cost by Person" : "Hours by Person",
                count: crewCosts.count
            )
            VStack(spacing: 0) {
                ForEach(crewCosts, id: \.employee.id) { row in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color.blue.opacity(0.1))
                            .frame(width: 36, height: 36)
                            .overlay(
                                Text(row.employee.initials)
                                    .font(.caption).bold()
                                    .foregroundColor(.blue)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.employee.fullName)
                                .font(.subheadline)
                            if let trade = row.employee.trade {
                                Text(trade)
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(row.hours.formatted() + " hrs")
                                .font(.subheadline).bold()
                            if showDollars {
                                Text(row.cost.currencyString)
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    if row.employee.id != crewCosts.last?.employee.id {
                        Divider().padding(.leading, 60)
                    }
                }
                if showDollars {
                    Divider()
                    HStack {
                        Text("Total Labour").font(.subheadline).bold()
                        Spacer()
                        Text(laborCost.currencyString).font(.subheadline).bold()
                    }
                    .padding(.horizontal).padding(.vertical, 10)
                }
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }

    // MARK: - Estimate vs Actual

    private func estimateVsActualSection(estimate: Estimate) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Estimated vs Actual Hours")
            VStack(spacing: 0) {
                // Header row
                HStack {
                    Text("Code").font(.caption).bold().foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    Text("Est Qty").font(.caption).bold().foregroundColor(.secondary).frame(width: 60, alignment: .trailing)
                    Text("Actual").font(.caption).bold().foregroundColor(.secondary).frame(width: 60, alignment: .trailing)
                    Text("Var").font(.caption).bold().foregroundColor(.secondary).frame(width: 52, alignment: .trailing)
                }
                .padding(.horizontal).padding(.vertical, 8)
                .background(Color(.systemGray6))

                ForEach(estimate.lineItems) { item in
                    let actual = hoursByCostCode.first { $0.code == item.code }
                    let actualHrs = (actual?.regular ?? 0) + (actual?.overtime ?? 0)
                    let variance = item.estimatedQuantity - actualHrs
                    let isOver   = variance < 0

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.code)
                                .font(.caption).bold()
                            Text(item.description)
                                .font(.caption2).foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text(item.estimatedQuantity.formatted())
                            .font(.caption).frame(width: 60, alignment: .trailing)

                        Text(actualHrs > 0 ? actualHrs.formatted() : "—")
                            .font(.caption).frame(width: 60, alignment: .trailing)

                        Text(actualHrs > 0 ? (isOver ? "-\(abs(variance).formatted())" : "+\(variance.formatted())") : "—")
                            .font(.caption).bold()
                            .foregroundColor(actualHrs == 0 ? .secondary : (isOver ? .red : .green))
                            .frame(width: 52, alignment: .trailing)
                    }
                    .padding(.horizontal).padding(.vertical, 9)

                    if item.id != estimate.lineItems.last?.id {
                        Divider().padding(.leading)
                    }
                }
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }

    // MARK: - Helpers

    private func utilizationColor(_ pct: Int) -> Color {
        if pct < 70 { return .green }
        if pct < 90 { return .orange }
        return .red
    }

    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date)     { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yest" }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE"
        return fmt.string(from: date)
    }
}

// MARK: - Cost Stat Cell

private struct CostStatCell: View {
    let value: String
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.system(size: 16))
            Text(value)
                .font(.subheadline).bold()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Project Cost Card (for Foreman Dashboard)

struct ProjectCostCard: View {
    let project: Project
    @EnvironmentObject var store: AppStore

    private var showDollars: Bool { !store.currentUserRole.isFieldRole }
    private var totalHours: Decimal { store.timesheets(for: project.id).reduce(0) { $0 + $1.totalHours } }
    private var laborCost:  Decimal { store.laborCost(for: project.id) }
    private var budget:     Decimal? { project.estimatedBudget ?? project.contractValue }
    private var utilization: Double {
        guard let b = budget, b > 0 else { return 0 }
        return min(NSDecimalNumber(decimal: laborCost / b).doubleValue, 1.0)
    }
    private var utilizationPct: Int { Int(utilization * 100) }

    var body: some View {
        NavigationLink {
            ProjectCostView(project: project)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(
                        showDollars ? "Project Costs" : "Project Hours",
                        systemImage: "chart.bar.fill"
                    )
                    .font(.subheadline).bold()
                    .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(totalHours.formatted() + " hrs")
                            .font(.title3).bold()
                        Text("Hours logged")
                            .font(.caption).foregroundColor(.secondary)
                    }

                    if showDollars {
                        Divider().frame(height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(laborCost.currencyString)
                                .font(.title3).bold()
                            Text("Labour cost")
                                .font(.caption).foregroundColor(.secondary)
                        }

                        if budget != nil {
                            Divider().frame(height: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(utilizationPct)%")
                                    .font(.title3).bold()
                                    .foregroundColor(utilizationColor(utilizationPct))
                                Text("Budget used")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }

                if showDollars, budget != nil {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color(.systemGray5))
                                .frame(height: 8)
                            RoundedRectangle(cornerRadius: 5)
                                .fill(utilizationColor(utilizationPct))
                                .frame(width: max(geo.size.width * CGFloat(utilization), 4), height: 8)
                        }
                    }
                    .frame(height: 8)
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(16)
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
    }

    private func utilizationColor(_ pct: Int) -> Color {
        if pct < 70 { return .green }
        if pct < 90 { return .orange }
        return .red
    }
}

// MARK: - Project Cost Banner Row (inline in ProjectDetailView)

struct ProjectCostBannerRow: View {
    let project: Project
    @EnvironmentObject var store: AppStore

    private var showDollars: Bool { !store.currentUserRole.isFieldRole }
    private var totalHours: Decimal { store.timesheets(for: project.id).reduce(0) { $0 + $1.totalHours } }
    private var laborCost:  Decimal { store.laborCost(for: project.id) }
    private var budget:     Decimal? { project.estimatedBudget ?? project.contractValue }
    private var utilization: Double {
        guard let b = budget, b > 0 else { return 0 }
        return min(NSDecimalNumber(decimal: laborCost / b).doubleValue, 1.0)
    }
    private var utilizationPct: Int { Int(utilization * 100) }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "clock.fill")
                    .foregroundColor(.blue)
                    .font(.system(size: 18))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(showDollars ? "Project Costs" : "Project Hours")
                    .font(.subheadline).bold()

                // Budget bar only for office/management roles
                if showDollars, budget != nil {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(.systemGray5)).frame(height: 6)
                            Capsule()
                                .fill(budgetBarColor)
                                .frame(width: max(geo.size.width * CGFloat(utilization), 3), height: 6)
                        }
                    }
                    .frame(height: 6)
                }

                HStack(spacing: 10) {
                    Text(totalHours.formatted() + " hrs logged")
                        .font(.caption).foregroundColor(.secondary)
                    if showDollars && laborCost > 0 {
                        Text("·").foregroundColor(.secondary).font(.caption)
                        Text(laborCost.currencyString + " labour")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    if showDollars, budget != nil {
                        Text("·").foregroundColor(.secondary).font(.caption)
                        Text("\(utilizationPct)% of budget")
                            .font(.caption)
                            .foregroundColor(budgetBarColor)
                            .bold()
                    }
                }
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var budgetBarColor: Color {
        if utilizationPct < 70 { return .green }
        if utilizationPct < 90 { return .orange }
        return .red
    }
}
