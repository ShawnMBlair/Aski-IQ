// ScheduleDayView.swift
// FieldOS – Schedule Day View

import SwiftUI

struct ScheduleDayView: View {
    let date: Date
    @EnvironmentObject var store: AppStore
    @State private var showCreateEntry = false

    private var entries: [ScheduleEntry] {
        store.scheduleEntries(for: date)
            .sorted { ($0.shiftStart ?? $0.date) < ($1.shiftStart ?? $1.date) }
    }

    /// Material-sale deliveries scheduled for this day.
    /// MaterialSale.requestedDeliveryDate is the natural calendar pin and is
    /// already populated whenever a sale has a delivery committed. Surfacing
    /// it on the schedule lets ops see "what's landing on the truck today"
    /// without flipping to the Material Sales tab.
    private var deliveries: [MaterialSale] {
        let cal = Calendar.current
        return store.materialSales
            .filter { sale in
                guard !sale.isDeleted, let due = sale.requestedDeliveryDate else { return false }
                return cal.isDate(due, inSameDayAs: date)
            }
            .sorted { ($0.saleNumber) < ($1.saleNumber) }
    }

    /// Contract milestones falling on this day — payment-due dates,
    /// retainage releases, insurance renewals, expiry warnings. The
    /// store helper centralizes the date-of filter so we stay in sync
    /// with the month-grid indicator.
    private var milestones: [ContractMilestone] {
        store.contractMilestones(for: date)
    }

    private var dateTitle: String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: date)
    }

    var body: some View {
        Group {
            if entries.isEmpty && deliveries.isEmpty && milestones.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 44))
                        .foregroundColor(.secondary)
                    Text("Nothing scheduled for \(dateTitle).")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Button("Add Shift") {
                        showCreateEntry = true
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(spacing: AskiSpacing.md) {
                        if !entries.isEmpty {
                            scheduleSectionHeader("Shifts", count: entries.count, icon: "person.3.fill")
                            ForEach(entries) { entry in
                                ScheduleEntryDetailRow(entry: entry)
                                    .padding(.horizontal)
                            }
                        }
                        if !deliveries.isEmpty {
                            scheduleSectionHeader("Material Deliveries", count: deliveries.count, icon: "shippingbox.fill")
                            ForEach(deliveries) { sale in
                                MaterialDeliveryRow(sale: sale)
                                    .padding(.horizontal)
                            }
                        }
                        if !milestones.isEmpty {
                            scheduleSectionHeader("Contract Milestones",
                                                  count: milestones.count,
                                                  icon: "doc.text.fill")
                            ForEach(milestones) { ms in
                                ContractMilestoneScheduleRow(milestone: ms)
                                    .padding(.horizontal)
                            }
                        }
                    }
                    .padding(.top, AskiSpacing.md)
                    .padding(.bottom, AskiSpacing.lg)
                }
            }
        }
        .sheet(isPresented: $showCreateEntry) {
            ScheduleEntryCreateEditView(preselectedDate: date)
        }
    }

    @ViewBuilder
    private func scheduleSectionHeader(_ title: String, count: Int, icon: String) -> some View {
        HStack(spacing: AskiSpacing.sm) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text("(\(count))")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, AskiSpacing.lg)
        .padding(.top, AskiSpacing.xs)
    }
}

// MARK: - Material delivery row

/// Row representing a material-sale delivery on the schedule. Compact like
/// ScheduleEntryDetailRow but tinted differently so users instantly tell a
/// crew shift apart from a delivery.
struct MaterialDeliveryRow: View {
    let sale: MaterialSale
    @EnvironmentObject var store: AppStore
    @State private var showDetail = false

    private var clientName: String {
        store.client(id: sale.clientID)?.name ?? "Unknown client"
    }

    private var lineSummary: String {
        let count = sale.lineItems.count
        return count == 0 ? "Delivery" : "\(count) line item\(count == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AskiSpacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(sale.saleNumber.isEmpty ? "Material sale" : sale.saleNumber)
                        .font(.headline)
                    Text(clientName).font(.subheadline).foregroundColor(.secondary)
                }
                Spacer()
                Text(sale.status.rawValue.capitalized)
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.16)))
                    .overlay(Capsule().stroke(Color.orange.opacity(0.35), lineWidth: 0.5))
                    .foregroundColor(.orange)
            }
            HStack(spacing: AskiSpacing.md) {
                Label(lineSummary, systemImage: "list.bullet.rectangle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let address = sale.deliveryAddress, !address.isEmpty {
                    Label(address, systemImage: "mappin")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(sale.grandTotal.currencyString)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(AskiSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: AskiRadius.card, style: .continuous)
                .fill(Color.orange.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AskiRadius.card, style: .continuous)
                .stroke(Color.orange.opacity(0.25), lineWidth: 0.75)
        )
        .onTapGesture { showDetail = true }
        .sheet(isPresented: $showDetail) {
            NavigationStack {
                MaterialSaleDetailView(sale: sale)
            }
        }
    }
}

// MARK: - Schedule Entry Detail Row

struct ScheduleEntryDetailRow: View {
    let entry: ScheduleEntry
    @EnvironmentObject var store: AppStore
    @State private var showEdit = false

    private var projectName: String {
        store.project(id: entry.projectID)?.name ?? "Unknown Project"
    }

    private var crewName: String? {
        entry.crewID.flatMap { store.crew(id: $0) }?.name
    }

    private var timeRange: String {
        guard let start = entry.shiftStart else { return "Time TBD" }
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        if let end = entry.shiftEnd {
            return "\(f.string(from: start)) – \(f.string(from: end))"
        }
        return f.string(from: start)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(projectName).font(.headline)
                    Text(timeRange).font(.subheadline).foregroundColor(.secondary)
                }
                Spacer()
                ScheduleStatusBadge(status: entry.status)
            }

            if let crew = crewName {
                Label(crew, systemImage: "person.3")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            if let task = entry.taskDescription {
                Text(task)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            if let location = entry.location {
                Label(location, systemImage: "mappin")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let costCode = entry.costCode {
                Label(costCode, systemImage: "number")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
        .onTapGesture { showEdit = true }
        .sheet(isPresented: $showEdit) {
            ScheduleEntryCreateEditView(existing: entry)
        }
    }
}

// MARK: - Schedule Status Badge

struct ScheduleStatusBadge: View {
    let status: ScheduleEntryStatus

    var body: some View {
        Text(status.rawValue.capitalized)
            .font(.caption2)
            .bold()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(6)
    }

    private var color: Color {
        switch status {
        case .scheduled: return .blue
        case .inProgress: return .orange
        case .completed: return .green
        case .cancelled: return .red
        case .rescheduled: return .purple
        }
    }
}

// MARK: - Contract milestone schedule row
//
// Compact card surfaced on the Schedule day view alongside shifts +
// material deliveries. Tapping pushes into ContractDetailView so the
// PM can act on it without leaving the calendar context.

struct ContractMilestoneScheduleRow: View {
    let milestone: ContractMilestone
    @EnvironmentObject var store: AppStore
    @State private var showDetail = false

    private var contract: Contract? {
        store.contracts.first(where: { $0.id == milestone.contractID })
    }

    /// Color follows the milestone's *effective* status so an upcoming
    /// row that's now overdue (date passed, status still 'upcoming')
    /// renders red without us having to rewrite the row on a cron.
    private var accent: Color {
        switch milestone.effectiveStatus {
        case .overdue:    return .red
        case .due:        return .orange
        case .upcoming:   return .blue
        case .completed:  return .green
        case .waived:     return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AskiSpacing.sm) {
            HStack(alignment: .top, spacing: AskiSpacing.md) {
                Image(systemName: milestone.milestoneType.icon)
                    .foregroundColor(accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(milestone.title)
                        .font(.headline)
                    if let c = contract {
                        Text("\(c.contractNumber ?? c.title) · \(c.counterpartyName)")
                            .font(.subheadline).foregroundColor(.secondary)
                    }
                    if let v = milestone.amountDue {
                        Text(v.formatted(.currency(code: contract?.currency ?? "USD")))
                            .font(.subheadline.weight(.semibold))
                    }
                }
                Spacer()
                Text(milestone.effectiveStatus.displayName.uppercased())
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(accent.opacity(0.16)))
                    .foregroundColor(accent)
            }
        }
        .padding(AskiSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: AskiRadius.card, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AskiRadius.card, style: .continuous)
                .stroke(accent.opacity(0.25), lineWidth: 0.75)
        )
        .onTapGesture { showDetail = true }
        .sheet(isPresented: $showDetail) {
            NavigationStack {
                ContractDetailView(contractID: milestone.contractID)
                    .environmentObject(store)
            }
        }
    }
}
