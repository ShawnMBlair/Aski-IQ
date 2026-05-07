// ContractChecklists.swift
// Aski IQ — Per-contract-type review checklists.
//
// WHY THIS EXISTS
// You said new PMs need to be able to read a contract; experienced PMs
// need a fast reference. A checklist is both: "a healthy <contract type>
// has these 8 things — here's what's covered and what's missing."
//
// SHIPPED IN-APP (no DB table)
// Same reasoning as the glossary. Stable, works offline, no migration
// to update copy. Phase 2 can layer per-company overrides on top via
// a DB table when companies start asking for that.
//
// AUTO-CHECK FROM AI REVIEW
// When the AI clause review finds a clause matching the item's
// `autoCheckClauseKinds`, the item is auto-checked — green tick, no
// manual action needed. Items can also be checked / unchecked by hand.
// Manual state lives on the contract via a JSONB column or
// (V1 simpler) computed live each time from the AI clauses + a
// ContractStore-side override map.
//
// V1 SCOPE
// This file ships the static checklist DEFINITIONS plus a helper that
// computes the checked / unchecked state for a contract by looking at
// the contract's clauses. Manual user toggles persist locally only
// (saved on the contract.notes JSON for now). Phase 2 can move that to
// a proper table.

import Foundation

// MARK: - Definitions

/// One item in a checklist. Some items can be auto-checked when the AI
/// review finds matching clause kinds; others are pure manual checks.
struct ChecklistItem: Identifiable, Equatable {
    let id: String                 // stable string key, lowercase + hyphenated
    let label: String              // short title in the row
    let detail: String             // one-line "what good looks like"
    /// Clause kinds whose presence on the contract auto-checks this item.
    /// Empty array = manual check only.
    let autoCheckClauseKinds: [ClauseKind]
}

/// Per-contract-type checklist. Total checked-out-of-total drives the
/// progress pill in ContractDetailView.
struct ContractChecklist: Equatable {
    let contractType: ContractType
    let title: String
    let items: [ChecklistItem]
}

// MARK: - The checklists

@MainActor
enum ContractChecklists {

    /// Looks up the checklist for a given contract type. Falls back to
    /// the generic `.other` list when no specific one exists.
    static func checklist(for type: ContractType) -> ContractChecklist {
        all.first(where: { $0.contractType == type }) ?? generic
    }

    /// Computes the auto-checked state given the contract's extracted
    /// clauses. Returns the checked set as item IDs.
    static func autoCheckedItems(for clauses: [ContractClause]) -> Set<String> {
        let presentKinds = Set(clauses.filter { !$0.isDeleted }.map { $0.clauseKind })
        var ids: Set<String> = []
        for list in all {
            for item in list.items {
                let needs = Set(item.autoCheckClauseKinds)
                if !needs.isEmpty && !needs.intersection(presentKinds).isEmpty {
                    ids.insert(item.id)
                }
            }
        }
        return ids
    }

    // MARK: - Static lists

    /// Catch-all when the contract type doesn't have a custom list.
    static let generic = ContractChecklist(
        contractType: .other,
        title: "Generic contract review",
        items: [
            .init(id: "scope-defined", label: "Scope clearly defined",
                  detail: "Specs, drawings, exhibits attached or incorporated by reference.",
                  autoCheckClauseKinds: [.scope]),
            .init(id: "payment-terms", label: "Payment terms specified",
                  detail: "Net days, milestone schedule, or T&M rates clearly stated.",
                  autoCheckClauseKinds: [.paymentTerms]),
            .init(id: "termination", label: "Termination clause",
                  detail: "Cure period, notice requirements, and termination-for-convenience covered.",
                  autoCheckClauseKinds: [.termination]),
            .init(id: "dispute", label: "Dispute resolution",
                  detail: "Mediation → arbitration or courts. Local jurisdiction.",
                  autoCheckClauseKinds: [.disputeResolution, .governingLaw]),
            .init(id: "indemnity", label: "Indemnity reviewed",
                  detail: "Mutual or comparative — never broad-form one-sided indemnity.",
                  autoCheckClauseKinds: [.indemnity]),
            .init(id: "notice", label: "Notice requirements",
                  detail: "Where + how to send formal notices for claims, defaults, terminations.",
                  autoCheckClauseKinds: [.notice])
        ]
    )

    /// All checklists. Add new ones here; the system picks them up
    /// automatically via `checklist(for:)`.
    static let all: [ContractChecklist] = [

        // ── Owner Prime contracts ───────────────────────────────────
        ContractChecklist(
            contractType: .ownerPrime,
            title: "Owner / Prime contract",
            items: [
                .init(id: "scope-of-work", label: "Scope of work",
                      detail: "Specs, drawings, schedules incorporated. Inclusions and exclusions explicit.",
                      autoCheckClauseKinds: [.scope]),
                .init(id: "payment-app-process", label: "Payment application process",
                      detail: "Schedule of values, lien waiver protocol, retainage % capped at 10%.",
                      autoCheckClauseKinds: [.paymentTerms, .retainage]),
                .init(id: "consequential-waiver", label: "Consequential damages waiver",
                      detail: "Mutual waiver of consequential damages — protects from lost-rent / lost-profit claims.",
                      autoCheckClauseKinds: [.limitationOfLiability]),
                .init(id: "indemnity-comparative", label: "Comparative indemnity",
                      detail: "We indemnify only for OUR negligence, not theirs. Reject broad-form.",
                      autoCheckClauseKinds: [.indemnity]),
                .init(id: "ld-cap", label: "Liquidated damages capped",
                      detail: "Daily rate disclosed and cap as % of contract value (typically 10%).",
                      autoCheckClauseKinds: [.liquidatedDamages]),
                .init(id: "no-damages-removed", label: "No 'no-damages-for-delay' clause",
                      detail: "If the owner causes a delay, we recover extended general conditions.",
                      autoCheckClauseKinds: []),
                .init(id: "differing-conditions", label: "Differing site conditions",
                      detail: "Defines what happens when site conditions differ from contract documents.",
                      autoCheckClauseKinds: []),
                .init(id: "change-orders", label: "Change order process",
                      detail: "Written orders required before work. T&M rates pre-defined for unscheduled work.",
                      autoCheckClauseKinds: [.changeOrders]),
                .init(id: "termination-cure", label: "Termination with cure period",
                      detail: "Default + 10-day cure period. Termination-for-convenience pays lost profit.",
                      autoCheckClauseKinds: [.termination]),
                .init(id: "warranty-period", label: "Warranty period bounded",
                      detail: "1-2 year industry standard. Avoid open-ended warranties.",
                      autoCheckClauseKinds: [.warranty]),
                .init(id: "insurance-clear", label: "Insurance requirements clear",
                      detail: "Coverage types + limits specified. Additional insured + waiver of subrogation language explicit.",
                      autoCheckClauseKinds: [.insurance]),
                .init(id: "dispute-mediation", label: "Mediation before arbitration / courts",
                      detail: "Filters small disputes cheaply. Local venue.",
                      autoCheckClauseKinds: [.disputeResolution, .governingLaw])
            ]
        ),

        // ── Subcontractor contracts (we are the GC) ─────────────────
        ContractChecklist(
            contractType: .subcontractor,
            title: "Subcontractor agreement",
            items: [
                .init(id: "flow-down", label: "Flow-down clause",
                      detail: "Sub bound to all obligations the prime imposes on us.",
                      autoCheckClauseKinds: [.flowDown]),
                .init(id: "scope-defined", label: "Scope defined with exclusions",
                      detail: "What's IN and what's OUT — prevents scope-creep arguments later.",
                      autoCheckClauseKinds: [.scope]),
                .init(id: "schedule-bound", label: "Bound to project schedule",
                      detail: "Mobilization date, milestone deadlines, completion date pinned.",
                      autoCheckClauseKinds: []),
                .init(id: "pay-when-paid", label: "Pay-when-paid (timing only)",
                      detail: "Timing-only PWP, never pay-IF-paid. Add backstop ('within 60 days regardless of owner').",
                      autoCheckClauseKinds: [.payWhenPaid]),
                .init(id: "lien-waiver-protocol", label: "Lien waiver protocol",
                      detail: "Conditional waiver per progress payment, unconditional only after funds clear.",
                      autoCheckClauseKinds: [.lienWaiver]),
                .init(id: "insurance-required", label: "Insurance certificates required",
                      detail: "Sub must carry CGL ($1M+), WC, Auto. AI/PNC endorsements named.",
                      autoCheckClauseKinds: [.insurance]),
                .init(id: "indemnity-flowdown", label: "Indemnity — sub indemnifies us",
                      detail: "Standard contractor flow-down: sub holds us harmless for their work.",
                      autoCheckClauseKinds: [.indemnity]),
                .init(id: "termination-cure", label: "Termination with cure period",
                      detail: "Right to terminate for default with 7-10 day cure. Right to take over and finish at sub's cost.",
                      autoCheckClauseKinds: [.termination]),
                .init(id: "change-order-process", label: "Change order process",
                      detail: "Written orders required. Sub agrees not to do extras without authorization.",
                      autoCheckClauseKinds: [.changeOrders]),
                .init(id: "warranty-1yr", label: "1-year warranty minimum",
                      detail: "Sub warrants workmanship for 12 months past substantial completion.",
                      autoCheckClauseKinds: [.warranty]),
                .init(id: "safety-compliance", label: "Safety + OSHA compliance",
                      detail: "Sub responsible for own crew safety. Right to suspend for safety violations.",
                      autoCheckClauseKinds: []),
                .init(id: "non-solicit", label: "Non-solicitation of personnel",
                      detail: "Sub can't poach our project staff during or shortly after the project.",
                      autoCheckClauseKinds: [])
            ]
        ),

        // ── Material Purchase contracts (we are the buyer) ──────────
        ContractChecklist(
            contractType: .materialPurchase,
            title: "Material purchase agreement",
            items: [
                .init(id: "delivery-date-firm", label: "Firm delivery date",
                      detail: "Specific date or short window. Late-delivery remedies (cover purchase, LDs).",
                      autoCheckClauseKinds: []),
                .init(id: "spec-conformance", label: "Specification conformance",
                      detail: "Material must meet exact specs in the order. Right to reject non-conforming goods.",
                      autoCheckClauseKinds: [.scope]),
                .init(id: "price-locked", label: "Price locked",
                      detail: "Unit prices fixed for the contract duration. Escalation clauses tied to objective indices only.",
                      autoCheckClauseKinds: []),
                .init(id: "warranty-passes-through", label: "Manufacturer warranty passes through",
                      detail: "Supplier assigns OEM warranty to us. We don't lose coverage by buying through them.",
                      autoCheckClauseKinds: [.warranty]),
                .init(id: "title-and-risk", label: "Title + risk of loss",
                      detail: "Title passes when delivered, not when shipped. Supplier carries risk in transit.",
                      autoCheckClauseKinds: []),
                .init(id: "lien-waiver-supplier", label: "Supplier lien waiver protocol",
                      detail: "Conditional waiver per payment to prevent supplier from liening the project.",
                      autoCheckClauseKinds: [.lienWaiver]),
                .init(id: "no-back-charges", label: "No surprise back-charges",
                      detail: "All fees disclosed up front. No 'small order' / 'rush' / 'fuel surcharge' add-ons.",
                      autoCheckClauseKinds: []),
                .init(id: "payment-terms-net", label: "Payment terms (Net 30+)",
                      detail: "Net 30 minimum. Avoid 2/10 Net 30 traps unless we're sure we'll take the discount.",
                      autoCheckClauseKinds: [.paymentTerms]),
                .init(id: "remedy-cap-removed", label: "No supplier liability cap below order value",
                      detail: "If supplier has a tiny remedy cap (e.g. only refund of price), our exposure on a defective batch is unbounded.",
                      autoCheckClauseKinds: [.limitationOfLiability])
            ]
        ),

        // ── NDA ─────────────────────────────────────────────────────
        ContractChecklist(
            contractType: .nda,
            title: "Non-Disclosure Agreement",
            items: [
                .init(id: "term-bounded", label: "Term ≤ 5 years",
                      detail: "Avoid perpetual NDAs. 3-5 years is standard.",
                      autoCheckClauseKinds: []),
                .init(id: "definition-tight", label: "Definition of 'confidential' tight",
                      detail: "Should require marking or post-disclosure designation. Avoid 'all communications' definitions.",
                      autoCheckClauseKinds: [.confidentiality]),
                .init(id: "carve-outs", label: "Standard carve-outs",
                      detail: "Public knowledge, independently developed, lawfully received from a third party — all excluded.",
                      autoCheckClauseKinds: [.confidentiality]),
                .init(id: "no-non-compete", label: "No non-compete buried inside",
                      detail: "Some NDAs sneak in non-compete or non-solicit. Strike them.",
                      autoCheckClauseKinds: []),
                .init(id: "return-or-destroy", label: "Return-or-destroy on request",
                      detail: "Counterparty can request return of confidential materials at any time.",
                      autoCheckClauseKinds: []),
                .init(id: "mutual", label: "Mutual (not one-way)",
                      detail: "Both sides bound, not just us — unless the deal is genuinely one-way.",
                      autoCheckClauseKinds: [])
            ]
        )
    ]
}

// MARK: - Live state for one contract

/// Combines the static checklist definition with the contract's actual
/// state — auto-checks from AI clauses, manual checks stored in the
/// contract's notes JSON. Used by ContractDetailView to render the
/// checklist tab + progress bar.
struct ContractChecklistState {
    let definition: ContractChecklist
    let autoChecked: Set<String>           // item IDs auto-checked from AI clauses
    let manualChecked: Set<String>         // item IDs the user toggled on

    /// Combined view: an item is "checked" if either auto or manual.
    var checkedIDs: Set<String> {
        autoChecked.union(manualChecked)
    }

    var checkedCount: Int { checkedIDs.intersection(definition.items.map { $0.id }).count }
    var totalCount: Int   { definition.items.count }
    var progress: Double  {
        totalCount > 0 ? Double(checkedCount) / Double(totalCount) : 0
    }
}
