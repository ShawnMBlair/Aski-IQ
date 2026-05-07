// ForemanDashboardView.swift
// FieldOS – Foreman Dashboard (Real Version)
// Replace the existing ForemanDashboardView.swift with this file.

import SwiftUI

struct ForemanDashboardView: View {
    @EnvironmentObject var store: AppStore
    @State private var showFieldQuickMode = false
    @State private var showUniversalSearch = false

    private var todayEntries: [ScheduleEntry] {
        store.scheduleEntries(for: Date())
            .sorted { ($0.shiftStart ?? $0.date) < ($1.shiftStart ?? $1.date) }
    }

    private var todayProject: Project? {
        todayEntries.first.flatMap { store.project(id: $0.projectID) }
    }

    private var todayCrew: Crew? {
        todayEntries.first?.crewID.flatMap { store.crew(id: $0) }
    }

    private var crewMembers: [Employee] {
        todayCrew?.memberIDs.compactMap { store.employee(id: $0) } ?? []
    }

    /// Drafts the foreman still needs to submit today. Excludes soft-deleted
    /// rows so cleared entries don't keep showing in the "needs attention"
    /// counter.
    private var draftTimesheetsToday: Int {
        store.timesheetEntries.filter {
            $0.approvalStatus == .draft &&
            !$0.isDeleted &&
            Calendar.current.isDateInToday($0.date)
        }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    topCards
                    shiftsSection
                    crewSection
                    actionsSection
                    Spacer(minLength: 80)
                }
                .padding(.top)
            }
            .navigationTitle(greetingTitle)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { showUniversalSearch = true } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Search")
                    Button { showFieldQuickMode = true } label: {
                        Label("Field Mode", systemImage: "bolt.fill").font(.subheadline)
                    }
                    .accessibilityLabel("Open Field Quick Mode")
                    .accessibilityHint("Clock in, clock out, and submit hours quickly")
                }
            }
            .sheet(isPresented: $showFieldQuickMode) { FieldQuickModeView() }
            .sheet(isPresented: $showUniversalSearch) {
                UniversalSearchSheet().environmentObject(store)
            }
        }
    }

    // MARK: - Sub-views

    private var topCards: some View {
        Group {
            WeatherCard()
            StartShiftCard(project: todayProject, crew: todayCrew, memberCount: crewMembers.count)
            if let project = todayProject { ProjectCostCard(project: project) }
        }
    }

    private var shiftsSection: some View {
        Group {
            SectionHeader(title: "Today's Shifts", count: todayEntries.count)
            if todayEntries.isEmpty {
                EmptyCard(message: "No shifts scheduled for today.")
            } else {
                ForEach(todayEntries) { entry in
                    ScheduleEntryDetailRow(entry: entry).padding(.horizontal)
                }
            }
        }
    }

    @ViewBuilder
    private var crewSection: some View {
        if !crewMembers.isEmpty {
            SectionHeader(title: "Crew on Site", count: crewMembers.count)
            ForemanCrewList(members: crewMembers, foremanID: todayCrew?.foremanID)
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        if draftTimesheetsToday > 0 {
            SectionHeader(title: "Hours to Submit", count: draftTimesheetsToday)
            NavigationLink(destination: TimesheetCrewEntryView()) {
                Label("Submit Today's Hours", systemImage: "checkmark.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity).padding()
                    .background(Color.orange).foregroundColor(.white)
                    .cornerRadius(12).padding(.horizontal)
            }
            .accessibilityLabel("Submit today's hours, \(draftTimesheetsToday) timesheet\(draftTimesheetsToday == 1 ? "" : "s") pending")
            .accessibilityHint("Opens the crew timesheet entry form")
        }
        NavigationLink(destination: ExceptionLogCreateView()) {
            Label("Log Exception / Delay", systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .frame(maxWidth: .infinity).padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12).padding(.horizontal)
        }
    }

    private var greetingTitle: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<12: return "Good Morning"
        case 12..<17: return "Good Afternoon"
        default: return "Good Evening"
        }
    }
}

// MARK: - Crew List (extracted to avoid deep TupleView nesting)

private struct ForemanCrewList: View {
    let members: [Employee]
    let foremanID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(members) { member in
                ForemanCrewRow(member: member, isForemanID: foremanID)
                if member.id != members.last?.id {
                    Divider().padding(.leading, 60)
                }
            }
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

private struct ForemanCrewRow: View {
    let member: Employee
    let isForemanID: UUID?

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.blue.opacity(0.12))
                .frame(width: 36, height: 36)
                .overlay(Text(member.initials).font(.subheadline).foregroundColor(.blue))
            VStack(alignment: .leading, spacing: 2) {
                Text(member.fullName).font(.subheadline).bold()
                if let trade = member.trade {
                    Text(trade).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            if member.id == isForemanID {
                Text("Foreman")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15))
                    .foregroundColor(.orange)
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal).padding(.vertical, 10)
    }
}

// MARK: - Start Shift Card (Real Version)

struct StartShiftCard: View {
    let project: Project?
    let crew: Crew?
    let memberCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            projectInfo
            NavigationLink(destination: StartShiftFlowView()) {
                StartShiftButton(isReady: project != nil)
            }
            .disabled(project == nil)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .padding(.horizontal)
    }

    @ViewBuilder
    private var projectInfo: some View {
        if let project {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Today's Project").font(.caption).foregroundColor(.secondary)
                    Text(project.name).font(.headline)
                    if let crew {
                        Label("\(crew.name) · \(memberCount) members", systemImage: "person.3")
                            .font(.subheadline).foregroundColor(.secondary)
                    }
                }
                Spacer()
                StatusBadge(status: project.status)
            }
        } else {
            Text("No shift scheduled for today.").font(.subheadline).foregroundColor(.secondary)
        }
    }
}

private struct StartShiftButton: View {
    let isReady: Bool
    var body: some View {
        Label("Start Shift", systemImage: "play.fill")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding()
            .background(isReady ? Color.green : Color(.systemGray4))
            .foregroundColor(.white)
            .cornerRadius(12)
    }
}
