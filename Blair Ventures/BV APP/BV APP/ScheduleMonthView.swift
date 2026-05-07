// ScheduleMonthView.swift
// Aski IQ — Month-grid view for the Schedule tab.
//
// Companion to ScheduleCalendarView (week strip) and ScheduleDayView (day list).
// Together they back the Day / Week / Month segmented control on the Schedule
// tab. Tap any day in the grid to bounce back into Day mode focused on it.

import SwiftUI

struct ScheduleMonthView: View {
    @EnvironmentObject var store: AppStore

    /// Bound from the parent so a tap on a day moves the parent into day mode.
    @Binding var selectedDate: Date
    @Binding var monthOffset: Int
    /// Closure invoked when a day cell is tapped — parent flips view mode to .day.
    var onTapDay: (Date) -> Void

    private let calendar = Calendar.current

    /// First day of the displayed month (after applying monthOffset).
    private var monthAnchor: Date {
        let today = calendar.startOfDay(for: Date())
        let firstOfThisMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: today)
        ) ?? today
        return calendar.date(byAdding: .month, value: monthOffset, to: firstOfThisMonth) ?? today
    }

    /// 6 rows × 7 cols = 42 day cells, padded with leading/trailing days from
    /// the adjacent months so every row is full and the layout doesn't shift
    /// month-to-month.
    private var gridDays: [Date] {
        let firstOfMonth = monthAnchor
        // Sunday-first week numbering (1 = Sun, 7 = Sat).
        let weekday = calendar.component(.weekday, from: firstOfMonth)
        let leadingDays = weekday - 1   // days from previous month to fill first row
        let gridStart = calendar.date(byAdding: .day, value: -leadingDays, to: firstOfMonth) ?? firstOfMonth
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    private var monthLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: monthAnchor)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Month nav
            HStack {
                Button { monthOffset -= 1 } label: {
                    Image(systemName: "chevron.left").padding(8)
                }
                .accessibilityLabel("Previous month")
                Spacer()
                Text(monthLabel)
                    .font(.headline)
                Spacer()
                Button { monthOffset += 1 } label: {
                    Image(systemName: "chevron.right").padding(8)
                }
                .accessibilityLabel("Next month")
            }
            .padding(.horizontal)
            .padding(.vertical, AskiSpacing.sm)

            // Weekday header
            HStack(spacing: 0) {
                ForEach(["S", "M", "T", "W", "T", "F", "S"], id: \.self) { letter in
                    Text(letter)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, AskiSpacing.sm)
            .padding(.bottom, 4)

            Divider()

            // Day grid
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7),
                    spacing: 4
                ) {
                    ForEach(gridDays, id: \.self) { day in
                        MonthDayCell(
                            date: day,
                            isInCurrentMonth: calendar.isDate(day, equalTo: monthAnchor, toGranularity: .month),
                            isToday: calendar.isDateInToday(day),
                            isSelected: calendar.isDate(day, inSameDayAs: selectedDate),
                            shiftCount: store.scheduleEntries(for: day).count,
                            deliveryCount: deliveryCount(for: day),
                            hasConflict: !store.conflictsOn(date: day)
                                .filter { $0.conflictType == .crewDoubleBooked }
                                .isEmpty
                        ) {
                            selectedDate = day
                            onTapDay(day)
                        }
                    }
                }
                .padding(.horizontal, AskiSpacing.sm)
                .padding(.top, 4)
                .padding(.bottom, AskiSpacing.lg)
            }
        }
    }

    /// Number of material-sale deliveries scheduled for this day. Treated as a
    /// second indicator (orange dot) on the day cell so users can see "what's
    /// landing on the truck today" at a glance.
    private func deliveryCount(for date: Date) -> Int {
        store.materialSales.reduce(0) { acc, sale in
            guard !sale.isDeleted, let due = sale.requestedDeliveryDate else { return acc }
            return calendar.isDate(due, inSameDayAs: date) ? acc + 1 : acc
        }
    }
}

// MARK: - Month day cell

private struct MonthDayCell: View {
    let date: Date
    let isInCurrentMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let shiftCount: Int
    let deliveryCount: Int
    let hasConflict: Bool
    let action: () -> Void

    private var dayNumber: String {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f.string(from: date)
    }

    private var background: Color {
        if isSelected { return .blue }
        if isToday    { return Color.blue.opacity(0.10) }
        return .clear
    }

    private var dayColor: Color {
        if isSelected      { return .white }
        if !isInCurrentMonth { return .secondary.opacity(0.5) }
        if isToday         { return .blue }
        return .primary
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(dayNumber)
                    .font(.subheadline.weight(isToday ? .bold : .regular))
                    .foregroundColor(dayColor)
                HStack(spacing: 3) {
                    if hasConflict {
                        Circle().fill(Color.red).frame(width: 5, height: 5)
                    } else if shiftCount > 0 {
                        Circle()
                            .fill(isSelected ? Color.white.opacity(0.85) : Color.blue)
                            .frame(width: 5, height: 5)
                    }
                    if deliveryCount > 0 {
                        Circle()
                            .fill(isSelected ? Color.white.opacity(0.6) : Color.orange)
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(height: 6)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: AskiRadius.chip, style: .continuous)
                    .fill(background)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [date.shortDate]
        if isToday { parts.append("Today") }
        if shiftCount > 0 { parts.append("\(shiftCount) shift\(shiftCount == 1 ? "" : "s")") }
        if deliveryCount > 0 { parts.append("\(deliveryCount) deliver\(deliveryCount == 1 ? "y" : "ies")") }
        if hasConflict { parts.append("conflict") }
        return parts.joined(separator: ", ")
    }
}
