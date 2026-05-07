// QuoteFromOpportunityView.swift
// BV APP – Create a Quote directly from a CRM Opportunity
// Sprint 9: One-tap quote creation with auto-stub estimate

import SwiftUI

// MARK: - Quote From Opportunity View

struct QuoteFromOpportunityView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let opportunity: CRMOpportunity
    var onCreated: ((Quote) -> Void)? = nil

    @State private var siteAddress:       String  = ""
    @State private var scopeSummary:      String  = ""
    @State private var inclusions:        String  = ""
    @State private var exclusions:        String  = ""
    @State private var assumptions:       String  = ""
    @State private var valueString:       String  = ""
    @State private var contingencyString: String  = "0"
    @State private var paymentTerms:      String  = ""
    @State private var validityDays:      Int     = 30
    @State private var showError:         Bool    = false
    @State private var errorMessage:      String  = ""

    // ── Derived ──────────────────────────────────────────────────────────────

    private var clientName: String {
        store.clients.first(where: { $0.id == opportunity.clientID })?.name ?? ""
    }

    private var subtotal: Decimal {
        Decimal(string: valueString.replacingOccurrences(of: ",", with: "")) ?? 0
    }

    private var contingency: Decimal {
        Decimal(string: contingencyString) ?? 0
    }

    private var contingencyAmount: Decimal { subtotal * contingency / 100 }
    private var totalBeforeTax: Decimal { subtotal + contingencyAmount }
    private var taxAmount: Decimal { totalBeforeTax * Decimal(AppSettings.shared.taxRate) / 100 }
    private var grandTotal: Decimal { totalBeforeTax + taxAmount }

    // ── Body ─────────────────────────────────────────────────────────────────

    var body: some View {
        NavigationStack {
            Form {

                // ── Opportunity context (read-only) ──────────────────────────
                Section {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(opportunity.stage.color.opacity(0.12))
                                .frame(width: 40, height: 40)
                            Image(systemName: opportunity.stage.icon)
                                .foregroundColor(opportunity.stage.color)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(opportunity.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            HStack(spacing: 4) {
                                Image(systemName: "building.2.fill")
                                    .font(.caption2).foregroundColor(.secondary)
                                Text(clientName)
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                // ── Site ─────────────────────────────────────────────────────
                Section("Site") {
                    TextField("Site Address", text: $siteAddress)
                }

                // ── Pricing ──────────────────────────────────────────────────
                Section("Pricing") {
                    HStack {
                        Text("Subtotal")
                        Spacer()
                        TextField("0.00", text: $valueString)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 130)
                    }
                    HStack {
                        Text("Contingency")
                        Spacer()
                        HStack(spacing: 4) {
                            TextField("0", text: $contingencyString)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 50)
                            Text("%").foregroundColor(.secondary)
                        }
                    }
                    if contingency > 0 {
                        HStack {
                            Text("Contingency Amount").foregroundColor(.secondary)
                            Spacer()
                            Text(currencyQ(contingencyAmount)).foregroundColor(.secondary)
                        }
                    }
                    HStack {
                        Text("Total (before tax)").fontWeight(.semibold)
                        Spacer()
                        Text(currencyQ(totalBeforeTax))
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(totalBeforeTax > 0 ? .primary : .secondary)
                    }
                    if AppSettings.shared.taxRate > 0 {
                        HStack {
                            Text("\(AppSettings.shared.taxLabel) (\(Int(AppSettings.shared.taxRate))%)")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(currencyQ(taxAmount)).foregroundColor(.secondary)
                        }
                        HStack {
                            Text("Grand Total").fontWeight(.bold)
                            Spacer()
                            Text(currencyQ(grandTotal))
                                .font(.headline.weight(.bold))
                                .foregroundColor(.green)
                        }
                    }
                }

                // ── Scope ─────────────────────────────────────────────────────
                Section("Scope Summary") {
                    TextEditor(text: $scopeSummary)
                        .frame(minHeight: 80)
                }

                Section("Inclusions") {
                    TextEditor(text: $inclusions)
                        .frame(minHeight: 60)
                }

                Section("Exclusions") {
                    TextEditor(text: $exclusions)
                        .frame(minHeight: 60)
                }

                Section("Assumptions") {
                    TextEditor(text: $assumptions)
                        .frame(minHeight: 60)
                }

                // ── Commercial ───────────────────────────────────────────────
                Section("Payment Terms") {
                    TextEditor(text: $paymentTerms)
                        .frame(minHeight: 60)
                }

                Section("Validity") {
                    Stepper("Valid for \(validityDays) days", value: $validityDays, in: 7...90, step: 7)
                }
            }
            .navigationTitle("Create Quote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { save() }
                        .fontWeight(.semibold)
                }
            }
            .alert("Missing Info", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .onAppear { prefill() }
        }
    }

    // ── Prefill ───────────────────────────────────────────────────────────────

    private func prefill() {
        let client = store.clients.first(where: { $0.id == opportunity.clientID })

        siteAddress  = opportunity.siteAddress.isEmpty
            ? (client?.sites.first(where: { $0.isDefault })?.address ?? "")
            : opportunity.siteAddress

        scopeSummary = !opportunity.description.isEmpty
            ? opportunity.description
            : opportunity.serviceType

        paymentTerms = client?.defaultPaymentTerms
            ?? AppSettings.shared.defaultPaymentTerms

        validityDays = AppSettings.shared.defaultQuoteValidityDays

        if opportunity.value > 0 {
            valueString = NSDecimalNumber(decimal: opportunity.value).stringValue
        }
    }

    // ── Save ──────────────────────────────────────────────────────────────────

    private func save() {
        guard subtotal > 0 else {
            errorMessage = "Enter the quote value before saving."
            showError = true
            return
        }

        // FIX: estimates use job numbers (J-NNNN), quotes use their own series (Q-YYYY-NNNN)
        let estJobNumber = AppSettings.shared.nextJobNumber()
        let quoteNumber  = store.nextQuoteNumber()

        // 1 — Stub estimate (awarded status so it satisfies Quote's FK)
        var estimate = Estimate(
            jobNumber: estJobNumber,
            clientID:  opportunity.clientID,
            name:      opportunity.title
        )
        estimate.status             = .awarded
        estimate.awardedDate        = Date()
        estimate.scopeDescription   = scopeSummary.isEmpty ? nil : scopeSummary
        estimate.contingencyPercent = contingency
        estimate.lineItems = [
            CostCodeItem(
                code:               "001",
                description:        opportunity.serviceType.isEmpty ? "Scope of Work" : opportunity.serviceType,
                unit:               "LS",
                estimatedQuantity:  1,
                unitRate:           subtotal
            )
        ]
        store.upsertEstimate(estimate)

        // 2 — Quote linked to estimate and opportunity
        var quote = Quote(
            jobNumber:  quoteNumber,    // FIX: Q-YYYY-NNNN, not the estimate's job number
            estimateID: estimate.id,
            clientID:   opportunity.clientID,
            clientName: clientName,
            preparedBy: store.currentUser?.fullName ?? ""
        )
        quote.opportunityID      = opportunity.id   // FIX: bi-directional link
        quote.siteAddress        = siteAddress.isEmpty ? nil : siteAddress
        quote.scopeSummary       = scopeSummary
        quote.inclusions         = inclusions
        quote.exclusions         = exclusions
        quote.assumptions        = assumptions
        quote.paymentTerms       = paymentTerms
        quote.subtotal           = subtotal          // manual fallback
        quote.lineItems          = estimate.lineItems // carry stub line item into quote
        quote.contingencyPercent = contingency
        quote.taxRate            = Decimal(AppSettings.shared.taxRate)
        quote.validityDays       = validityDays
        quote.expiryDate         = Calendar.current.date(
            byAdding: .day, value: validityDays, to: Date()
        ) ?? Date()
        store.upsertQuote(quote)

        // 3 — Link back to opportunity + advance stage
        // upsertQuote() already auto-links via estimateID, but we set it explicitly
        // here too so the link is immediate without waiting for the auto-link scan.
        var updatedOpp          = opportunity
        updatedOpp.quoteID      = quote.id
        updatedOpp.estimateID   = estimate.id
        updatedOpp.syncStatus   = .pending   // ensure Supabase gets the updated links
        if updatedOpp.stage != .won && updatedOpp.stage != .lost {
            updatedOpp.stage       = .quoteSent
            updatedOpp.probability = OpportunityStage.quoteSent.defaultProbability
        }
        updatedOpp.updatedAt = Date()
        store.upsertCRMOpportunity(updatedOpp)
        Task { await SyncEngine.shared.pushPendingCRMOpportunities() }

        // 4 — Activity log
        store.logCRMActivity(
            type:          .quoteSent,
            title:         "Quote created: \(quoteNumber)",
            notes:         scopeSummary,
            clientID:      opportunity.clientID,
            contactID:     opportunity.contactID,
            opportunityID: opportunity.id,
            quoteID:       quote.id,
            projectID:     nil
        )

        onCreated?(quote)
        dismiss()
    }
}

// ── Local currency helper (avoids redeclaration conflict) ─────────────────────

private func currencyQ(_ d: Decimal) -> String {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.locale = .current
    return f.string(from: d as NSDecimalNumber) ?? "$0"
}
