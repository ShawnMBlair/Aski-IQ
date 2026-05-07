// CRMAIViews.swift
// BV APP – CRM AI Intelligence Cards

import SwiftUI

// MARK: - AI Hub View (CRM tab 5)

struct CRMAIHubView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var coachService = CRMAIService()

    private var activeOpps: [CRMOpportunity] {
        store.crmOpportunities.filter { $0.stage != .lost && $0.stage != .won }
    }
    private var topOpps: [CRMOpportunity] {
        Array(activeOpps.sorted { $0.value > $1.value }.prefix(5))
    }

    var body: some View {
        VStack(spacing: 16) {

            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CRM Intelligence")
                        .font(.title3.weight(.bold))
                    Text("\(activeOpps.count) active deals · Powered by Claude")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundColor(.purple)
            }
            .padding(.horizontal, 4)

            // API key warning
            if AppSettings.shared.anthropicAPIKey.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "key.fill")
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("API Key Required")
                            .font(.subheadline.weight(.semibold))
                        Text("Add your Anthropic API key in Settings → AI Features to enable all AI tools.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(14)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(12)
            }

            // Pipeline Coach
            pipelineCoachCard

            // Loss Pattern Analysis
            CRMLossPatternsCard()
                .environmentObject(store)

            // Top Deals — quick brief access
            if !topOpps.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Top Deals — Pre-Call Brief")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 4)
                    ForEach(topOpps) { opp in
                        NavigationLink(destination: CRMOpportunityDetailView(opportunity: opp)
                            .environmentObject(store)) {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(opp.stage.color.opacity(0.12))
                                        .frame(width: 36, height: 36)
                                    Image(systemName: "phone.fill")
                                        .font(.system(size: 14))
                                        .foregroundColor(opp.stage.color)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(opp.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Text(opp.stage.rawValue + " · " + formattedValue(opp.value))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "sparkles")
                                    .font(.caption)
                                    .foregroundColor(.purple)
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(12)
                            .background(Color(.secondarySystemGroupedBackground))
                            .cornerRadius(12)
                        }
                    }
                }
            }
        }
    }

    private var pipelineCoachCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.purple.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.purple)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pipeline Coach")
                        .font(.subheadline.weight(.semibold))
                    Text("Claude · Whole-pipeline assessment")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if coachService.result != nil {
                    Button {
                        Task { await runCoach() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.purple)
                    }
                }
            }
            .padding(14)

            Divider()

            if activeOpps.isEmpty {
                Text("No active deals in the pipeline yet.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(14)
            } else if coachService.isLoading {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.85)
                    Text("Analyzing pipeline…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(16)
            } else if let result = coachService.result {
                AIMarkdownView(text: result)
                    .padding(14)
            } else if let err = coachService.error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(err).font(.caption).foregroundColor(.secondary)
                }
                .padding(14)
            } else {
                Button {
                    Task { await runCoach() }
                } label: {
                    Label("Analyse My Pipeline", systemImage: "brain.head.profile")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.purple.opacity(0.1))
                        .foregroundColor(.purple)
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .padding(14)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private func runCoach() async {
        await coachService.generatePipelineCoaching(
            opportunities: activeOpps,
            activities: store.crmActivities
        )
    }

    private func formattedValue(_ v: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.maximumFractionDigits = 0
        f.locale = .current
        return f.string(from: v as NSDecimalNumber) ?? "$0"
    }
}

// MARK: - Call Brief Card (in Opportunity Detail)

struct CRMCallBriefCard: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var service = CRMAIService()

    let opportunity: CRMOpportunity

    private var clientName: String {
        store.clients.first(where: { $0.id == opportunity.clientID })?.name ?? "Unknown"
    }
    private var contacts: [CRMContact] {
        store.contacts(for: opportunity.clientID)
    }
    private var recentActivities: [CRMActivity] {
        Array(store.crmActivities.filter { $0.opportunityID == opportunity.id }.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.purple.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "sparkles")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.purple)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Pre-Call Brief")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text("Claude · Talking points & strategy")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if service.result != nil {
                    Button {
                        Task { await generateBrief() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.purple)
                    }
                }
            }
            .padding(14)

            Divider()

            // Body
            if service.isLoading {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.85)
                    Text("Generating brief…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(16)
            } else if let result = service.result {
                AIMarkdownView(text: result)
                    .padding(14)
            } else if let err = service.error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(14)
            } else {
                Button {
                    Task { await generateBrief() }
                } label: {
                    Label("Generate Pre-Call Brief", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.purple.opacity(0.1))
                        .foregroundColor(.purple)
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .padding(14)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private func generateBrief() async {
        await service.generateCallBrief(
            opportunity: opportunity,
            clientName: clientName,
            contacts: contacts,
            recentActivities: recentActivities
        )
    }
}

// MARK: - Win Insight Card (in Opportunity Detail)

struct CRMWinInsightCard: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var service = CRMAIService()

    let opportunity: CRMOpportunity

    private var clientName: String {
        store.clients.first(where: { $0.id == opportunity.clientID })?.name ?? "Unknown"
    }
    private var activities: [CRMActivity] {
        store.crmActivities.filter { $0.opportunityID == opportunity.id }
    }
    private var daysSinceCreated: Int {
        Calendar.current.dateComponents([.day], from: opportunity.createdAt, to: Date()).day ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.indigo.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.indigo)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Win Probability Insight")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text("Claude · Honest deal assessment")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if service.result != nil {
                    Button {
                        Task { await generateInsight() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.indigo)
                    }
                }
            }
            .padding(14)

            Divider()

            if service.isLoading {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.85)
                    Text("Analyzing deal…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(16)
            } else if let result = service.result {
                AIMarkdownView(text: result)
                    .padding(14)
            } else if let err = service.error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(14)
            } else {
                Button {
                    Task { await generateInsight() }
                } label: {
                    Label("Analyse Win Probability", systemImage: "chart.line.uptrend.xyaxis")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.indigo.opacity(0.1))
                        .foregroundColor(.indigo)
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .padding(14)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private func generateInsight() async {
        await service.generateWinInsight(
            opportunity: opportunity,
            clientName: clientName,
            activities: activities,
            daysSinceCreated: daysSinceCreated
        )
    }
}

// MARK: - Loss Patterns Card (in CRM Reports)

struct CRMLossPatternsCard: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var service = CRMAIService()

    private var lostOpportunities: [CRMOpportunity] {
        store.crmOpportunities.filter { $0.stage == .lost }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.red.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.red)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Loss Pattern Analysis")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text("Claude · Why we're losing deals")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("\(lostOpportunities.count) lost")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(14)

            Divider()

            if lostOpportunities.isEmpty {
                Text("No lost opportunities to analyze yet.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(14)
            } else if service.isLoading {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.85)
                    Text("Analyzing loss patterns…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(16)
            } else if let result = service.result {
                AIMarkdownView(text: result)
                    .padding(14)
                Button {
                    Task { await service.generateLossPatterns(lostOpportunities: lostOpportunities) }
                } label: {
                    Label("Refresh Analysis", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            } else if let err = service.error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(err).font(.caption).foregroundColor(.secondary)
                }
                .padding(14)
            } else {
                Button {
                    Task { await service.generateLossPatterns(lostOpportunities: lostOpportunities) }
                } label: {
                    Label("Analyse Loss Patterns", systemImage: "lightbulb")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.1))
                        .foregroundColor(.red)
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .padding(14)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
}

// MARK: - Markdown Renderer (lightweight)

struct AIMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(parsedBlocks, id: \.id) { block in
                switch block.kind {
                case .heading:
                    Text(block.content)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .padding(.top, 4)
                case .bullet:
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text(block.content)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                    }
                case .body:
                    Text(block.content)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }
            }
        }
    }

    private struct Block: Identifiable {
        let id: Int  // stable index-based — no UUID allocation on every render
        enum Kind { case heading, bullet, body }
        let kind: Kind
        let content: String
    }

    private var parsedBlocks: [Block] {
        var index = 0
        return text.components(separatedBy: "\n").compactMap { line -> Block? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            defer { index += 1 }
            if trimmed.hasPrefix("## ") {
                return Block(id: index, kind: .heading, content: String(trimmed.dropFirst(3)))
            } else if trimmed.hasPrefix("# ") {
                return Block(id: index, kind: .heading, content: String(trimmed.dropFirst(2)))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                return Block(id: index, kind: .bullet, content: String(trimmed.dropFirst(2)))
            } else if trimmed.hasPrefix("**") && trimmed.hasSuffix("**") {
                return Block(id: index, kind: .heading, content: trimmed.replacingOccurrences(of: "**", with: ""))
            } else {
                let cleaned = trimmed
                    .replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: "__", with: "")
                return Block(id: index, kind: .body, content: cleaned)
            }
        }
    }
}
