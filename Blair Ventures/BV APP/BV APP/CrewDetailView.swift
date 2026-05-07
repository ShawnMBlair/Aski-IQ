// CrewDetailView.swift
// FieldOS – Crew Detail

import SwiftUI

struct CrewDetailView: View {
    let crew: Crew
    @EnvironmentObject var store: AppStore
    @State private var showEdit = false

    private var foreman: Employee? {
        crew.foremanID.flatMap { store.employee(id: $0) }
    }

    private var members: [Employee] {
        crew.memberIDs.compactMap { store.employee(id: $0) }
    }

    private var assignedProjects: [Project] {
        store.projects.filter { $0.assignedCrewIDs.contains(crew.id) }
    }

    private var upcomingSchedule: [ScheduleEntry] {
        store.scheduleEntries
            .filter { $0.crewID == crew.id && $0.date >= Date() }
            .sorted { $0.date < $1.date }
            .prefix(3)
            .map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // MARK: - Header Card
                VStack(spacing: 12) {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.blue)

                    Text(crew.name)
                        .font(.title2).bold()

                    if let foreman {
                        HStack {
                            Image(systemName: "star.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text("Foreman: \(foreman.fullName)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let notes = crew.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(16)
                .padding(.horizontal)

                // MARK: - Stats
                HStack(spacing: 12) {
                    MiniKPICard(value: "\(members.count)", label: "Members", icon: "person.3")
                    MiniKPICard(value: "\(assignedProjects.count)", label: "Projects", icon: "folder")
                    MiniKPICard(value: "\(upcomingSchedule.count)", label: "Upcoming", icon: "calendar")
                }
                .padding(.horizontal)

                // MARK: - Members
                SectionHeader(title: "Crew Members", count: members.count)
                if members.isEmpty {
                    EmptyCard(message: "No members assigned.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(members) { member in
                            NavigationLink {
                                EmployeeDetailView(employee: member)
                            } label: {
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(Color.blue.opacity(0.15))
                                        .frame(width: 36, height: 36)
                                        .overlay(
                                            Text(member.initials)
                                                .font(.subheadline)
                                                .foregroundColor(.blue)
                                        )
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(member.fullName).font(.subheadline).bold()
                                            if member.id == crew.foremanID {
                                                Image(systemName: "star.fill")
                                                    .font(.caption2)
                                                    .foregroundColor(.orange)
                                            }
                                        }
                                        if let trade = member.trade {
                                            Text(trade).font(.caption).foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding()
                            }
                            if member.id != members.last?.id {
                                Divider().padding(.leading, 60)
                            }
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)
                }

                // MARK: - Assigned Projects
                SectionHeader(title: "Assigned Projects", count: assignedProjects.count)
                if assignedProjects.isEmpty {
                    EmptyCard(message: "Not assigned to any projects.")
                } else {
                    ForEach(assignedProjects) { project in
                        NavigationLink {
                            ProjectDetailView(project: project)
                        } label: {
                            ProjectSummaryRow(project: project)
                                .padding(.horizontal)
                        }
                    }
                }

                // MARK: - Upcoming Schedule
                SectionHeader(title: "Upcoming Shifts", count: upcomingSchedule.count)
                if upcomingSchedule.isEmpty {
                    EmptyCard(message: "No upcoming shifts.")
                } else {
                    ForEach(upcomingSchedule) { entry in
                        ScheduleEntryRow(entry: entry)
                    }
                }

                // Phase 1 — full crew calendar (week view, all days)
                NavigationLink {
                    CrewCalendarView(crew: crew)
                        .environmentObject(store)
                } label: {
                    HStack {
                        Image(systemName: "calendar")
                            .foregroundColor(.blue)
                        Text("View Full Schedule")
                            .font(.subheadline.bold())
                            .foregroundColor(.blue)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(10)
                    .padding(.horizontal)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 32)
            }
            .padding(.top)
        }
        .navigationTitle(crew.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Edit") { showEdit = true }
            }
        }
        .sheet(isPresented: $showEdit) {
            CrewCreateEditView(existing: crew)
        }
    }
}
