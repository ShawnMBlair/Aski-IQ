// BudgetActualService.swift
// Aski IQ — Phase 3 PMI workflow: live Budget vs Actual rollup.
//
// PURPOSE
// Pre-fix the app had `ProjectBudget` (the baseline) and the four
// cost sources (timesheets, POs, material requests, change orders)
// living independently. Nothing rolled them together into the
// "Original / Approved COs / Revised / Committed / Actual / Forecast /
// Margin / Variance" row a PM expects to see. PMs were doing the
// math by hand in Excel.
//
// THIS FILE
// One service that computes — on demand, no DB columns required —
// every budget metric for a project from existing live state. Each
// metric has its own helper so the UI can pull just what it needs
// (e.g. Dashboard tile vs full Budget card).
//
// CALCULATION MODEL
//   Original budget   = ProjectBudget.originalContractValue
//                       (falls back to project.contractValue if no
//                        ProjectBudget row exists yet)
//   Approved CO total = sum of approved COs' effectiveCostImpact
//   Revised budget    = Original + Approved CO total
//   Pending CO total  = sum of submitted/pendingApproval COs (not
//                       added to revised; tracked separately so PMs
//                       can see exposure)
//   Labor actual      = sum(timesheet.totalHours × employee.regularRate)
//                       only employees with a known rate are counted;
//                       others are flagged via `unratedTimesheetCount`
//   Material actual   = committedMaterialCost (PO rollup, already
//                       implemented in ProjectBudget extension)
//   Other actual      = invoiced material sales charged to the
//                       project (rare — defaults to 0)
//   Actual cost       = Labor + Material + Other
//   Forecast cost     = Actual + (totalBudgeted - Actual_committed)
//                       i.e. assume remaining budget will be spent.
//                       PMs can override later by editing the budget;
//                       this is the standard PMI Earned Value default.
//   Margin            = Revised - ActualCost
//   Variance          = ActualCost - TotalBudgeted (negative = under)
//   PercentSpent      = ActualCost / TotalBudgeted
//
// LIMITATIONS (DOCUMENTED)
//   * No multi-currency conversion. All values are summed at face
//     value; if the project has mixed-currency invoices (rare) the
//     totals are not meaningful. Phase 3.5 if needed.
//   * "Other actual" doesn't include equipment usage time —
//     equipment cost tracking would require a per-equipment hourly
//     rate field that doesn't exist yet.
//   * Labor cost ignores burden (taxes, insurance, benefits) —
//     burden multiplier is a per-company config that's not yet
//     surfaced. Phase 4 if companies request it.

import Foundation

@MainActor
struct ProjectBudgetActuals {
    let projectID:           UUID
    let originalBudget:      Decimal
    let approvedCOTotal:     Decimal
    let pendingCOTotal:      Decimal
    let revisedBudget:       Decimal      // = original + approvedCO
    let contingency:         Decimal
    let totalBudgetedLines:  Decimal      // sum of ProjectBudgetLine totals
    let laborActual:         Decimal
    let materialCommitted:   Decimal      // POs not draft/cancelled
    let otherActual:         Decimal
    let actualCost:          Decimal      // labor + material + other
    let forecastCost:        Decimal
    let margin:              Decimal      // revised - actual
    let variance:            Decimal      // actual - totalBudgeted (neg = under)
    let percentSpent:        Double
    let unratedTimesheetCount: Int
    let openChangeOrderCount: Int

    /// Field-reported labor hours (from approved DJRs) that don't have
    /// a matching timesheet. Phase 4 PMI feed: foremen log hours daily;
    /// payroll timesheets often lag by 1–2 weeks. These hours are NOT
    /// rolled into `laborActual` (timesheets are the source of truth)
    /// but are surfaced so the PM knows actuals are about to climb.
    let pendingFieldLaborHours: Double
    let pendingFieldLaborEstimatedCost: Decimal

    /// True when actuals exceed total budget (PMI threshold for
    /// "over budget" notification). UI surfaces a red badge here.
    var isOverBudget: Bool { variance > 0 }

    /// True when actuals exceed 80% of total budget — early warning
    /// before full overrun. Drives an orange "watch" badge in lists.
    var isApproachingBudget: Bool { percentSpent >= 0.80 && !isOverBudget }

    /// True when projected margin is below 10% of revised contract.
    /// Configurable threshold lives in `BudgetActualService.minMargin`.
    var isMarginBelowTarget: Bool {
        guard revisedBudget > 0 else { return false }
        let marginPct = NSDecimalNumber(decimal: margin / revisedBudget).doubleValue
        return marginPct < BudgetActualService.minMarginRatio
    }
}

@MainActor
enum BudgetActualService {

    /// Margin alert threshold. 10% is the conservative default for
    /// industrial trades; companies with thinner margins should
    /// override per-tenant in a future Settings field.
    static let minMarginRatio: Double = 0.10

    /// Single entry point — compute all metrics for one project.
    /// Returns a struct so the UI can read in one shot without
    /// firing off 8 separate computed properties on AppStore (each
    /// of which would re-evaluate on every body refresh).
    static func actuals(for projectID: UUID, in store: AppStore) -> ProjectBudgetActuals {
        let budgetRow = store.budget(for: projectID)
        let proj      = store.project(id: projectID)

        let original  = budgetRow?.originalContractValue
            ?? proj?.contractValue
            ?? 0
        let cont      = budgetRow?.contingencyAmount ?? 0
        let lineTotal = budgetRow?.totalLinesBudgeted ?? 0

        let approvedCOs = store.changeOrders(for: projectID)
            .filter { $0.status == .approved && !$0.isDeleted }
        let pendingCOs = store.changeOrders(for: projectID)
            .filter { $0.status.isOpen && !$0.isDeleted }
        let approvedCOTotal = approvedCOs.reduce(Decimal(0)) { $0 + $1.effectiveCostImpact }
        let pendingCOTotal  = pendingCOs.reduce(Decimal(0)) { $0 + $1.effectiveCostImpact }

        // Labor actuals — sum of (totalHours × rate) for timesheets
        // tied to this project. We pull rates from the `Employee`
        // record; timesheets without a rated employee are counted
        // separately so the PM knows actuals are understated.
        var labor = Decimal(0)
        var unrated = 0
        let projectTimesheets = store.timesheetEntries.filter {
            $0.projectID == projectID && !$0.isDeleted
        }
        for ts in projectTimesheets {
            if let emp = store.employees.first(where: { $0.id == ts.employeeID }),
               let rate = emp.regularRate {
                // Simple rate × hours. Overtime burden left for Phase 4.
                labor += rate * ts.totalHours
            } else {
                unrated += 1
            }
        }

        // Phase 4 — DJR labor gap. Walk approved DJRs for this project
        // and sum any crew-entry hours that DON'T have a matching
        // timesheet (same projectID + employeeID + same calendar day).
        // Crew entries without an employeeID always count — there's no
        // payroll record to pair them to. We only consider .approved
        // DJRs to avoid double-counting drafts the foreman is still
        // editing. The cost estimate uses the employee's regular rate
        // when available; unmatched names are valued at $0 (and the
        // hours number alone is shown as a non-zero advisory).
        var pendingHours: Double = 0
        var pendingCost = Decimal(0)
        let cal = Calendar.current
        let djrs = store.dailyJobReports(for: projectID).filter {
            !$0.isDeleted && $0.status == .approved
        }
        for djr in djrs {
            for crew in djr.crewEntries where crew.hoursWorked > 0 {
                let timesheetExists: Bool = {
                    guard let empID = crew.employeeID else { return false }
                    return projectTimesheets.contains { ts in
                        ts.employeeID == empID
                            && cal.isDate(ts.date, inSameDayAs: djr.reportDate)
                    }
                }()
                if !timesheetExists {
                    let billable = crew.hoursWorked + crew.overtime
                    pendingHours += billable
                    if let empID = crew.employeeID,
                       let rate = store.employees.first(where: { $0.id == empID })?.regularRate {
                        pendingCost += rate * Decimal(billable)
                    }
                }
            }
        }

        let materialCommitted = store.committedMaterialCost(for: projectID)

        // "Other" actuals reserved for future equipment / rental cost
        // rollups. Currently zero; declared so the metric is stable
        // when those land.
        let otherActual = Decimal(0)

        let actual   = labor + materialCommitted + otherActual
        let revised  = original + approvedCOTotal
        // When the PM has filled in detailed budget lines, use them as
        // the cost denominator. When they haven't, fall back to revised
        // contract + contingency so a project with only a headline
        // contract value still produces meaningful % spent / variance
        // numbers (instead of dividing actuals by 0).
        let lineBudget = lineTotal + cont
        let totalBudget = lineBudget > 0 ? lineBudget : (revised + cont)
        let margin   = revised - actual
        let variance = actual - totalBudget

        // Forecast — PMI standard "estimate at completion" is
        // EAC = AC + (BAC - EV). For our simpler model where we
        // don't track Earned Value formally yet, treat the forecast
        // as: "actual to date plus expected remaining" where
        // remaining is total budget minus what we've actually spent
        // (clamped to 0 so a project that's already overrun doesn't
        // produce a forecast LOWER than actual).
        let remaining = max(totalBudget - actual, 0)
        let forecast  = actual + remaining

        let percentSpent: Double
        if totalBudget > 0 {
            percentSpent = NSDecimalNumber(decimal: actual / totalBudget).doubleValue
        } else {
            percentSpent = 0
        }

        return ProjectBudgetActuals(
            projectID:             projectID,
            originalBudget:        original,
            approvedCOTotal:       approvedCOTotal,
            pendingCOTotal:        pendingCOTotal,
            revisedBudget:         revised,
            contingency:           cont,
            totalBudgetedLines:    lineTotal,
            laborActual:           labor,
            materialCommitted:     materialCommitted,
            otherActual:           otherActual,
            actualCost:            actual,
            forecastCost:          forecast,
            margin:                margin,
            variance:              variance,
            percentSpent:          percentSpent,
            unratedTimesheetCount: unrated,
            openChangeOrderCount:  pendingCOs.count,
            pendingFieldLaborHours: pendingHours,
            pendingFieldLaborEstimatedCost: pendingCost
        )
    }
}
