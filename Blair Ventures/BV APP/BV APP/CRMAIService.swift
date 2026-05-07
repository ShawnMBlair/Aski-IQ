// CRMAIService.swift
// BV APP – AI Lead Intelligence via Claude

import Foundation
import SwiftUI
import Combine

// MARK: - CRM AI Service

final class CRMAIService: ObservableObject {

    // MARK: State

    @Published var isLoading   = false
    @Published var result: String? = nil
    @Published var error: String?  = nil

    // `claude-sonnet-4-6` doesn't exist on Anthropic's API — it
    // returned `not_found_error` in production. Switched to the
    // unversioned `claude-sonnet-4-5` alias which resolves to the
    // current 4.5-series snapshot.
    private let model = "claude-sonnet-4-5"

    // MARK: - Pre-Call Brief

    /// Generates a pre-call brief for a sales rep about to contact a prospect.
    @MainActor
    func generateCallBrief(
        opportunity: CRMOpportunity,
        clientName: String,
        contacts: [CRMContact],
        recentActivities: [CRMActivity]
    ) async {
        // No client-side API-key check: ai-proxy holds the Anthropic key
        // server-side and returns a typed error (.notConfigured) if the
        // company hasn't activated AI yet.
        isLoading = true; result = nil; error = nil

        let contactsText = contacts.map {
            "- \($0.fullName), \($0.title)\($0.phone.isEmpty ? "" : " | \($0.phone)")\($0.email.isEmpty ? "" : " | \($0.email)")"
        }.joined(separator: "\n")

        let activitiesText = recentActivities.prefix(8).map {
            "[\(shortDate($0.date))] \($0.type.rawValue): \($0.title)"
        }.joined(separator: "\n")

        let valueStr = formatCurrency(opportunity.value)

        let prompt = """
        You are a sales advisor for a construction and industrial services company.
        A sales rep is about to make contact with a prospect. Generate a concise pre-call brief.

        **Opportunity:** \(opportunity.title)
        **Client:** \(clientName)
        **Stage:** \(opportunity.stage.rawValue)
        **Value:** \(valueStr)
        **Service Type:** \(opportunity.serviceType)
        **Lead Source:** \(opportunity.source.rawValue)
        **Win Probability:** \(opportunity.probability)%
        **Site:** \(opportunity.siteAddress.isEmpty ? "Not set" : opportunity.siteAddress)
        **Notes:** \(opportunity.notes.isEmpty ? "None" : opportunity.notes)

        **Contacts:**
        \(contactsText.isEmpty ? "No contacts on file" : contactsText)

        **Recent Activity:**
        \(activitiesText.isEmpty ? "No activity yet" : activitiesText)

        Write a brief with these sections (use markdown headers):
        ## Goal for This Call
        ## Key Context
        ## Suggested Talking Points (3-4 bullets)
        ## Watch Out For
        ## Recommended Next Step

        Keep it under 300 words. Be direct and practical — this is for a busy field services sales rep.
        """

        await callClaude(prompt: prompt)
    }

    // MARK: - Win Probability Insight

    /// Analyzes an opportunity and provides a narrative win likelihood assessment.
    @MainActor
    func generateWinInsight(
        opportunity: CRMOpportunity,
        clientName: String,
        activities: [CRMActivity],
        daysSinceCreated: Int
    ) async {
        isLoading = true; result = nil; error = nil

        let activitiesText = activities.prefix(10).map {
            "[\(shortDate($0.date))] \($0.type.rawValue): \($0.title)"
        }.joined(separator: "\n")

        let prompt = """
        You are a win/loss analyst for a construction and industrial services company.
        Analyze this opportunity and provide a frank win probability assessment.

        **Opportunity:** \(opportunity.title)
        **Client:** \(clientName)
        **Stage:** \(opportunity.stage.rawValue)
        **Value:** \(formatCurrency(opportunity.value))
        **Service Type:** \(opportunity.serviceType)
        **Lead Source:** \(opportunity.source.rawValue)
        **Current Probability:** \(opportunity.probability)%
        **Days in Pipeline:** \(daysSinceCreated)
        **Loss Reason (if any):** \(opportunity.lossReason.isEmpty ? "N/A" : opportunity.lossReason)
        **Notes:** \(opportunity.notes.isEmpty ? "None" : opportunity.notes)

        **Activity History:**
        \(activitiesText.isEmpty ? "No activity recorded" : activitiesText)

        Write your assessment with these sections (use markdown headers):
        ## Signals Working in Our Favour
        ## Risk Factors
        ## Honest Assessment
        ## What Would Improve Our Odds

        Be direct and honest. Under 250 words. Focus on actionable intelligence.
        """

        await callClaude(prompt: prompt)
    }

    // MARK: - Pipeline Coaching

    /// Analyzes all active deals and surfaces top coaching actions.
    @MainActor
    func generatePipelineCoaching(
        opportunities: [CRMOpportunity],
        activities: [CRMActivity]
    ) async {
        guard !opportunities.isEmpty else {
            error = "No active opportunities to analyze."
            return
        }
        isLoading = true; result = nil; error = nil

        let oppText = opportunities.prefix(15).map { opp -> String in
            let lastActivity = activities
                .filter { $0.opportunityID == opp.id }
                .sorted { $0.date > $1.date }
                .first
            let lastTouch = lastActivity.map { shortDate($0.date) } ?? "Never"
            return "- \(opp.title) | \(opp.stage.rawValue) | \(formatCurrency(opp.value)) | \(opp.probability)% prob | Last touch: \(lastTouch)"
        }.joined(separator: "\n")

        let totalValue = opportunities.reduce(Decimal(0)) { $0 + $1.value }

        let prompt = """
        You are a sales coach for a construction and industrial services company.
        Review the current pipeline and give the sales team actionable coaching guidance.

        **Pipeline Summary:**
        - Total active deals: \(opportunities.count)
        - Total pipeline value: \(formatCurrency(totalValue))

        **Active Deals:**
        \(oppText)

        Write your coaching with these sections (use markdown headers):
        ## Pipeline Health
        ## Deals at Risk (identify by name, explain why)
        ## Quick Wins This Week (2-3 specific actions)
        ## What to Stop Doing

        Be direct and specific. Name actual deals where relevant. Under 300 words.
        """

        await callClaude(prompt: prompt)
    }

    // MARK: - Loss Pattern Analysis

    /// Looks across all lost deals and surfaces patterns.
    @MainActor
    func generateLossPatterns(lostOpportunities: [CRMOpportunity]) async {
        guard !lostOpportunities.isEmpty else {
            error = "No lost opportunities to analyze."
            return
        }
        isLoading = true; result = nil; error = nil

        let lostText = lostOpportunities.prefix(20).map {
            "- \($0.title) | \($0.serviceType) | \(formatCurrency($0.value)) | Source: \($0.source.rawValue) | Reason: \($0.lossReason.isEmpty ? "Not recorded" : $0.lossReason)"
        }.joined(separator: "\n")

        let prompt = """
        You are a sales strategy advisor for a construction and industrial services company.
        Analyze these lost opportunities and identify patterns.

        **Lost Opportunities (\(lostOpportunities.count) total):**
        \(lostText)

        Write your analysis with these sections (use markdown headers):
        ## Top Loss Themes (2-3 patterns)
        ## Which Service Types Are We Losing Most?
        ## Lead Sources with Lowest Conversion
        ## Recommended Actions (3 specific things to change)

        Be direct. Under 300 words. Focus on what the sales team can act on immediately.
        """

        await callClaude(prompt: prompt)
    }

    // MARK: - Core API Call
    //
    // Routes through `AIProxyClient`, which forwards to the `ai-proxy`
    // Edge Function. The function holds the Anthropic key as a Supabase
    // secret, authenticates the user via JWT, and writes an
    // `audit_snapshots` row for every call.

    @MainActor
    private func callClaude(prompt: String) async {
        // Phase-2 deferred: tenant-customizable CRM brief tone.
        // The CRM service originally sent the full request as a
        // single user message — we now layer an OPTIONAL system
        // message on top when the admin has configured one for the
        // .crmBrief surface. Tenants who haven't configured one see
        // no behavior change (empty fallback → no system field added).
        let companyOverride = CompanyAIPromptService.shared.effectivePrompt(
            for:      .crmBrief,
            fallback: ""
        )
        var payload: [String: Any] = [
            "model":      model,
            "max_tokens": 1024,
            "messages":   [["role": "user", "content": prompt]]
        ]
        if !companyOverride.isEmpty {
            payload["system"] = companyOverride
        }
        switch await AIProxyClient.shared.sendText(payload: payload) {
        case .success(let text):
            result = text
        case .failure(let err):
            error = err.userMessage
        }
        isLoading = false
    }

    // MARK: - Helpers

    private static let shortDateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()

    private func shortDate(_ date: Date) -> String {
        Self.shortDateFmt.string(from: date)
    }

    private func formatCurrency(_ value: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.maximumFractionDigits = 0
        f.locale = .current
        return f.string(from: value as NSDecimalNumber) ?? "$0"
    }
}
