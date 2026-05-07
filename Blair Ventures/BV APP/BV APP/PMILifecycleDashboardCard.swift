// PMILifecycleDashboardCard.swift
// Aski IQ — Phase 5 PMI workflow: process-aligned dashboard card.
//
// PURPOSE
// Renders the five PMI process groups (Initiating / Planning /
// Executing / Monitoring / Closing) as a single card on the
// management dashboard. Each phase shows a count + dollar value;
// tap drills into a list of the items in that bucket.
//
// VISIBILITY
// Always visible to managers/execs. Phases with zero items render
// faded so the card layout is stable; users still get the "you have
// nothing in Closing right now" signal at a glance.

import SwiftUI

struct PMILifecycleDashboardCard: View {
    @EnvironmentObject var store: AppStore

    private var summary: ProjectLifecycleSummary {
        ProjectLifecycleService.summary(for: store)
    }

    var body: some View {
        let s = summary
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Project Lifecycle", systemImage: "arrow.triangle.branch")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(s.liveBookedValue.currencyString) live")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(ProjectLifecyclePhase.allCases) { phase in
                    NavigationLink {
                        PMILifecyclePhaseDetailView(phase: phase)
                    } label: {
                        PMILifecyclePhaseRow(bucket: s.bucket(phase))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .padding(.horizontal)
    }
}

// MARK: - Phase Row

private struct PMILifecyclePhaseRow: View {
    let bucket: ProjectLifecycleBucket

    private var tint: Color { phaseColor(bucket.phase) }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(tint.opacity(bucket.isEmpty ? 0.06 : 0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: bucket.phase.icon)
                    .foregroundColor(bucket.isEmpty ? .secondary : tint)
                    .font(.subheadline)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(bucket.phase.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(bucket.isEmpty ? .secondary : .primary)
                Text(bucket.phase.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(bucket.count)")
                    .font(.headline)
                    .foregroundColor(bucket.isEmpty ? .secondary : .primary)
                if bucket.totalValue > 0 {
                    Text(bucket.totalValue.currencyString)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Phase Detail View

struct PMILifecyclePhaseDetailView: View {
    @EnvironmentObject var store: AppStore
    let phase: ProjectLifecyclePhase

    private var bucket: ProjectLifecycleBucket {
        ProjectLifecycleService.summary(for: store).bucket(phase)
    }

    private var projects: [Project] {
        let ids = Set(bucket.projectIDs)
        return store.projects
            .filter { ids.contains($0.id) }
            .sorted { $0.name < $1.name }
    }

    private var estimates: [Estimate] {
        let ids = Set(bucket.estimateIDs)
        return store.estimates
            .filter { ids.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var quotes: [Quote] {
        let ids = Set(bucket.quoteIDs)
        return store.quotes
            .filter { ids.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var opportunities: [CRMOpportunity] {
        let ids = Set(bucket.opportunityIDs)
        return store.crmOpportunities
            .filter { ids.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if bucket.isEmpty {
                    emptyState
                } else {
                    if !projects.isEmpty {
                        SectionHeader(title: "Projects", count: projects.count)
                        ForEach(projects) { proj in
                            NavigationLink {
                                ProjectDetailView(project: proj)
                            } label: {
                                ProjectSummaryRow(project: proj)
                                    .padding(.horizontal)
                            }
                        }
                    }

                    if !estimates.isEmpty {
                        SectionHeader(title: "Estimates", count: estimates.count)
                        ForEach(estimates) { est in
                            NavigationLink {
                                EstimateDetailView(estimate: est)
                            } label: {
                                LifecycleSimpleRow(
                                    title:    est.jobNumber.isEmpty ? est.name : est.jobNumber,
                                    subtitle: est.name,
                                    value:    est.totalEstimated,
                                    badge:    est.status.displayName
                                )
                                .padding(.horizontal)
                            }
                        }
                    }

                    if !quotes.isEmpty {
                        SectionHeader(title: "Quotes", count: quotes.count)
                        ForEach(quotes) { q in
                            NavigationLink {
                                QuoteDetailView(quote: q)
                            } label: {
                                LifecycleSimpleRow(
                                    title:    q.jobNumber,
                                    subtitle: q.clientName,
                                    value:    q.grandTotal,
                                    badge:    q.status.displayName
                                )
                                .padding(.horizontal)
                            }
                        }
                    }

                    if !opportunities.isEmpty {
                        SectionHeader(title: "CRM Opportunities", count: opportunities.count)
                        ForEach(opportunities) { opp in
                            NavigationLink {
                                CRMOpportunityDetailView(opportunity: opp)
                            } label: {
                                LifecycleSimpleRow(
                                    title:    opp.title.isEmpty ? "Opportunity" : opp.title,
                                    subtitle: store.client(id: opp.clientID)?.name ?? "—",
                                    value:    opp.value,
                                    badge:    opp.stage.rawValue
                                )
                                .padding(.horizontal)
                            }
                        }
                    }
                }

                Spacer(minLength: 40)
            }
            .padding(.top, 16)
        }
        .navigationTitle(phase.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(phaseColor(phase).opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: phase.icon)
                        .foregroundColor(phaseColor(phase))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(phase.title)
                        .font(.title3.weight(.semibold))
                    Text(phase.subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 16) {
                LifecycleStat(label: "Items",  value: "\(bucket.count)", color: .primary)
                Divider().frame(height: 30)
                LifecycleStat(label: "Value",  value: bucket.totalValue.currencyString, color: .primary)
            }
            .padding(.top, 4)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.title)
                .foregroundColor(.secondary)
            Text("Nothing in \(phase.title) right now")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Helpers

private struct LifecycleSimpleRow: View {
    let title:    String
    let subtitle: String
    let value:    Decimal
    let badge:    String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if value > 0 {
                    Text(value.currencyString).font(.subheadline.weight(.semibold))
                }
                Text(badge)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(Capsule())
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }
}

private struct LifecycleStat: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline).foregroundColor(color)
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
    }
}

private func phaseColor(_ phase: ProjectLifecyclePhase) -> Color {
    switch phase.colorName {
    case "blue":   return .blue
    case "purple": return .purple
    case "green":  return .green
    case "orange": return .orange
    case "indigo": return .indigo
    default:       return .secondary
    }
}
