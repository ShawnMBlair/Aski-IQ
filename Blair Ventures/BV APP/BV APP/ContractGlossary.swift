// ContractGlossary.swift
// Aski IQ — Built-in plain-English explanations for the construction
// contract terms field-ops staff hit most often.
//
// WHY THIS EXISTS
// New PMs read a contract, see "pay-when-paid" or "consequential
// damages waiver", and either (a) ignore it because they don't know
// what it means or (b) sign and learn what it meant when they get
// burned. This glossary lives in the app, taps anywhere a term
// appears, and explains the term in 60-100 words plus a one-line
// "why this matters to you" risk note.
//
// SHIPPED IN-APP
// The glossary is hardcoded data, not a DB table. Reasons:
//   * Stable across deployments (no migration to update copy)
//   * Available offline (field workers read contracts on slow networks)
//   * No per-tenant variation needed for V1
// Future Phase 2 can layer per-company terms on top via a DB table.

import Foundation

/// One glossary entry. Aliases lets us match "pay when paid", "PWP",
/// "pay-when-paid clause" all to the same term.
struct ContractGlossaryEntry: Identifiable, Equatable {
    let id: String              // canonical term key, lowercased + hyphenated
    let term: String            // display label
    let aliases: [String]       // alternative phrasings
    let plainEnglish: String    // the explanation
    let whyItMatters: String    // 1-line risk / leverage note
    let category: Category

    enum Category: String, CaseIterable {
        case payment       = "Payment"
        case riskAllocation = "Risk Allocation"
        case scopeAndChange = "Scope & Change"
        case dispute       = "Dispute"
        case timing        = "Timing & Delivery"
        case insurance     = "Insurance & Bonding"
        case lien          = "Lien & Security"
        case general       = "General"
    }
}

@MainActor
final class ContractGlossary {
    static let shared = ContractGlossary()
    private init() {}

    /// All entries, alpha-sorted by term — used by the full glossary
    /// browse view and the search index.
    let entries: [ContractGlossaryEntry] = ContractGlossary.seed.sorted {
        $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending
    }

    /// Look up a term by its display name or any alias. Case-insensitive.
    /// Returns nil when no match — caller should fall back to "no
    /// definition available" copy.
    func lookup(_ raw: String) -> ContractGlossaryEntry? {
        let needle = raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        for e in entries {
            if e.term.lowercased() == needle { return e }
            if e.aliases.contains(where: { $0.lowercased() == needle }) { return e }
        }
        return nil
    }

    /// Substring-tolerant search for the in-app glossary browser.
    func search(_ query: String) -> [ContractGlossaryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { e in
            if e.term.lowercased().contains(q) { return true }
            if e.aliases.contains(where: { $0.lowercased().contains(q) }) { return true }
            return e.plainEnglish.lowercased().contains(q)
        }
    }

    /// Group entries by category for the browser view.
    func grouped() -> [(ContractGlossaryEntry.Category, [ContractGlossaryEntry])] {
        ContractGlossaryEntry.Category.allCases.compactMap { cat in
            let inCat = entries.filter { $0.category == cat }
            return inCat.isEmpty ? nil : (cat, inCat)
        }
    }

    // MARK: - Seed data
    //
    // ~50 of the most consequential terms. New entries can be added
    // here freely; build-time only, no migration. Keep `plainEnglish`
    // under ~120 words and `whyItMatters` to one direct sentence.

    private static let seed: [ContractGlossaryEntry] = [
        .init(id: "pay-when-paid",
              term: "Pay-When-Paid",
              aliases: ["pwp", "pay when paid", "pay-when-paid clause"],
              plainEnglish: "A clause where the general contractor only has to pay you (the sub) AFTER they get paid by the owner. Treated by some courts as a timing rule; in others, as a flat condition that can leave you unpaid forever if the owner defaults.",
              whyItMatters: "Push to delete or convert to 'pay-when-paid within X days' so you have a hard backstop if the owner stalls.",
              category: .payment),

        .init(id: "pay-if-paid",
              term: "Pay-If-Paid",
              aliases: ["pip", "pay if paid"],
              plainEnglish: "Stricter cousin of pay-when-paid: the GC's obligation to pay you is conditional on them collecting from the owner first. If the owner never pays, you legally don't get paid either.",
              whyItMatters: "Treat any pay-if-paid language as a deal-breaker on private work. Many states won't enforce it — but you don't want to litigate it.",
              category: .payment),

        .init(id: "retainage",
              term: "Retainage",
              aliases: ["holdback", "retention"],
              plainEnglish: "A percentage (typically 5%–10%) of each progress payment that the owner withholds until substantial completion. Released after punch list, lien-period expiry, or final acceptance depending on the contract.",
              whyItMatters: "10% retainage on a $1M sub is $100K of your cash sitting in someone else's bank account for months. Negotiate reductions at 50% completion.",
              category: .payment),

        .init(id: "liquidated-damages",
              term: "Liquidated Damages",
              aliases: ["lds", "ld", "delay damages"],
              plainEnglish: "A fixed dollar amount per day (or per week) that you owe if the project is late. Substitutes for the owner having to prove their actual losses — they just multiply days late × the rate.",
              whyItMatters: "Cap LDs as a percent of contract value (e.g. 10% max) and tie the trigger to the owner's own delays being separately accounted for.",
              category: .timing),

        .init(id: "consequential-damages-waiver",
              term: "Consequential Damages Waiver",
              aliases: ["consequential damages", "no consequential damages"],
              plainEnglish: "A mutual waiver where neither party can sue the other for indirect losses (lost profits, lost productivity, lost financing) that flow from a breach. Limits exposure to direct, measurable damages.",
              whyItMatters: "Always demand a mutual waiver. Without one, a one-week delay can balloon into a 'I lost the lease, I lost the tenant' multi-million-dollar claim.",
              category: .riskAllocation),

        .init(id: "indemnity",
              term: "Indemnity",
              aliases: ["indemnification", "hold harmless"],
              plainEnglish: "You agree to defend, pay for, and absorb claims that someone else (the owner, GC) gets sued over — even if the claim is partially their fault. The breadth of the language matters enormously.",
              whyItMatters: "Insist on 'comparative' indemnity (you cover only your share of fault), not 'broad' indemnity (you cover everything including their negligence).",
              category: .riskAllocation),

        .init(id: "limitation-of-liability",
              term: "Limitation of Liability",
              aliases: ["loll", "liability cap"],
              plainEnglish: "A cap on how much you can owe in damages, usually a multiple of the contract value or a flat dollar amount. Distinct from indemnity — applies to all damages, not just third-party claims.",
              whyItMatters: "Aim for the contract value as a cap. No cap = your house and savings are on the line for one bad job.",
              category: .riskAllocation),

        .init(id: "flow-down",
              term: "Flow-Down Clause",
              aliases: ["incorporated by reference", "pass-through"],
              plainEnglish: "All the obligations the GC owes the owner (under the prime contract) are pushed down onto you (the sub). You're bound to terms you may have never read.",
              whyItMatters: "Demand a copy of the prime contract. If it has an unreasonable LD or indemnity, you're on the hook too.",
              category: .general),

        .init(id: "change-order",
              term: "Change Order",
              aliases: ["co", "change directive"],
              plainEnglish: "A signed amendment that modifies scope, price, or schedule. Only enforceable if signed before the work is done — verbal directions ('just do it, we'll paper it later') are unrecoverable in many contracts.",
              whyItMatters: "Never start changed work without a signed CO. If pushed, send a written 'change directive' and bill T&M while you negotiate.",
              category: .scopeAndChange),

        .init(id: "force-majeure",
              term: "Force Majeure",
              aliases: ["act of god", "unforeseen events"],
              plainEnglish: "Extraordinary events outside your control — pandemics, wildfires, strikes, war — that excuse a delay or non-performance. Coverage depends entirely on how the clause is worded.",
              whyItMatters: "Confirm pandemics, supply-chain disruptions, and labor strikes are explicitly listed. Otherwise you may not be covered.",
              category: .timing),

        .init(id: "termination-for-convenience",
              term: "Termination for Convenience",
              aliases: ["t4c", "termination for convenience clause"],
              plainEnglish: "The owner (or GC above you) can terminate the contract for ANY reason, with notice. You get paid for work completed plus reasonable demobilization costs — usually NOT lost profit on the unbuilt portion.",
              whyItMatters: "Negotiate to recover lost profit on a fixed margin (e.g. 10% of unbilled scope) — otherwise a 'we changed our minds' email costs you the project's profit.",
              category: .scopeAndChange),

        .init(id: "termination-for-cause",
              term: "Termination for Cause",
              aliases: ["termination for default"],
              plainEnglish: "The other party can terminate because YOU breached. Triggers usually include failure to pay subs, repeated safety violations, or persistent failure to make progress. Usually requires written cure notice.",
              whyItMatters: "Make sure the cure period is at least 7-10 days and that 'persistent failure' is defined, not subjective.",
              category: .scopeAndChange),

        .init(id: "warranty",
              term: "Warranty Period",
              aliases: ["warranty", "warranty obligations"],
              plainEnglish: "How long you're on the hook to come back and fix defects in the work without a new contract. Industry-standard is 1 year from substantial completion; some specs push to 2-5.",
              whyItMatters: "Long warranty periods compound risk because callbacks are nearly always money-losers. Stick to 12 months unless the price reflects a longer obligation.",
              category: .general),

        .init(id: "lien-waiver-conditional",
              term: "Conditional Lien Waiver",
              aliases: ["conditional waiver", "progress lien waiver"],
              plainEnglish: "A document where you waive your lien rights ON CONDITION that you receive the payment named on it. If the check bounces or never arrives, the waiver is void and your rights survive.",
              whyItMatters: "Only sign conditional waivers tied to specific invoices. Never sign 'conditional upon final payment' without a corresponding check in hand.",
              category: .lien),

        .init(id: "lien-waiver-unconditional",
              term: "Unconditional Lien Waiver",
              aliases: ["unconditional waiver", "final lien waiver"],
              plainEnglish: "Permanently waives your lien rights regardless of whether the check clears. Once signed, you cannot lien for that period of work even if you never get paid.",
              whyItMatters: "Only sign AFTER funds clear. A common scam is 'sign this unconditional, the wire is on its way' — then no wire.",
              category: .lien),

        .init(id: "joint-check",
              term: "Joint Check",
              aliases: ["joint check agreement", "jca"],
              plainEnglish: "A 3-party agreement where the upstream party (owner or GC) writes checks payable jointly to two parties below them — typically the GC and the sub, or the sub and a supplier. Both have to endorse.",
              whyItMatters: "Use joint-check agreements with material suppliers when you don't have a credit line — guarantees the supplier gets paid and protects you from a supplier lien on the project.",
              category: .lien),

        .init(id: "mechanics-lien",
              term: "Mechanic's Lien",
              aliases: ["construction lien", "lien"],
              plainEnglish: "A statutory right to claim a security interest in the improved property if you're not paid. Each state has strict notice and filing deadlines (often 60-120 days from last work). Miss them and the right vanishes.",
              whyItMatters: "Track your lien deadlines from day 1, not when payment is late. By the time you realize you have a problem, the window has often closed.",
              category: .lien),

        .init(id: "schedule-of-values",
              term: "Schedule of Values",
              aliases: ["sov"],
              plainEnglish: "A breakdown of the contract value across line items (mobilization, foundations, framing, finishes, etc.) used to compute progress payments. Front-loaded SoVs help cash flow; back-loaded ones strangle it.",
              whyItMatters: "Front-load mobilization, materials, and early-phase line items. Don't let the owner force a flat or back-loaded SoV.",
              category: .payment),

        .init(id: "substantial-completion",
              term: "Substantial Completion",
              aliases: ["sub-com", "sub. completion"],
              plainEnglish: "The point at which the work is sufficiently complete that the owner can use the project for its intended purpose, even if punch list items remain. Triggers warranty, retainage release, and the start of the lien period.",
              whyItMatters: "Push for substantial completion certification ASAP — every day of delay extends your lien risk and freezes your retainage.",
              category: .timing),

        .init(id: "punch-list",
              term: "Punch List",
              aliases: ["punchlist", "deficiency list"],
              plainEnglish: "The list of small items needing correction or completion before final acceptance. Ideally generated jointly at substantial completion; the contract should cap how long you have to address them (usually 30-60 days).",
              whyItMatters: "If the punch list is open-ended, the owner can hold final retainage forever by adding items. Cap the punch-list period in the contract.",
              category: .timing),

        .init(id: "additional-insured",
              term: "Additional Insured",
              aliases: ["ai endorsement"],
              plainEnglish: "An endorsement to your liability insurance that names someone else (typically the GC or owner) as covered. Lets them tap your policy directly instead of suing you to indirect them.",
              whyItMatters: "AI endorsements are cheap to add and often required. Make sure your policy supports them and that the certificate is delivered before site mobilization.",
              category: .insurance),

        .init(id: "primary-and-non-contributory",
              term: "Primary and Non-Contributory",
              aliases: ["pnc", "primary non-contributory"],
              plainEnglish: "Insurance language requiring YOUR policy to pay first (primary) and not seek contribution from the other party's policy (non-contributory) when both might apply.",
              whyItMatters: "If they require P&NC, your premium goes up. Push back on requirement language unless the contract specifically demands it.",
              category: .insurance),

        .init(id: "performance-bond",
              term: "Performance Bond",
              aliases: ["p-bond"],
              plainEnglish: "A 3-party guarantee from a surety that you'll perform the contract. If you default, the surety either finishes the job or pays the contract value. Typically 100% of contract value.",
              whyItMatters: "Bonds aren't insurance — the surety can come after you for everything they pay out. Treat bond claims as existential events.",
              category: .insurance),

        .init(id: "payment-bond",
              term: "Payment Bond",
              aliases: ["labor and material bond", "l&m bond"],
              plainEnglish: "A surety bond that guarantees subs and suppliers below you get paid if you can't pay them. Typically required on public work and replaces lien rights on federal projects.",
              whyItMatters: "If you're a sub on a bonded project, file a bond claim within the statutory window (often 90 days) — it's typically faster than litigation.",
              category: .insurance),

        .init(id: "no-damages-for-delay",
              term: "No Damages for Delay",
              aliases: ["nddf", "no-damages clause"],
              plainEnglish: "The owner gets schedule extensions but pays you NOTHING for delays they caused. You eat your own extended overhead, equipment standby, and idle labor.",
              whyItMatters: "Refuse this clause. Many states find it unenforceable in extreme cases, but you don't want to litigate. Insist on at least extended general conditions.",
              category: .timing),

        .init(id: "differing-site-conditions",
              term: "Differing Site Conditions",
              aliases: ["dsc", "changed conditions"],
              plainEnglish: "A clause covering what happens when actual site conditions are materially different from what the contract documents indicated (e.g. rock instead of soil, contaminated soil, hidden utilities). Usually entitles you to time and money.",
              whyItMatters: "Document differing conditions immediately with photos, surveyor reports, and notice letters. The longer you wait the harder the claim becomes.",
              category: .scopeAndChange),

        .init(id: "notice-of-claim",
              term: "Notice of Claim",
              aliases: ["claim notice", "notice"],
              plainEnglish: "A written notice you must give within a specific window (often 7-21 days) when something happens that entitles you to extra time or money — change, delay, differing condition. Miss the deadline, lose the claim.",
              whyItMatters: "Calendar every claim trigger. A missed 14-day notice on a $500K change is a $500K loss, not a paperwork issue.",
              category: .scopeAndChange),

        .init(id: "time-is-of-the-essence",
              term: "Time is of the Essence",
              aliases: ["toe"],
              plainEnglish: "Magic legal language that elevates schedule deadlines from 'targets' to 'material obligations'. A breach of a TOE deadline can be grounds for termination; without it, late performance is usually just damages.",
              whyItMatters: "If TOE is in the contract, treat every milestone date as binding. Routine 1-2 week slippage that's tolerated elsewhere can become a default here.",
              category: .timing),

        .init(id: "incorporation-by-reference",
              term: "Incorporation by Reference",
              aliases: ["incorporated documents"],
              plainEnglish: "A clause saying 'the following documents are part of this contract' — usually the prime contract, plans, specs, schedules, exhibits. Whatever's incorporated binds you whether or not you've read it.",
              whyItMatters: "Always demand copies of every document referenced. 'Incorporated by reference' to a document you don't have is a black box of risk.",
              category: .general),

        .init(id: "warranty-of-design",
              term: "Warranty of Design",
              aliases: ["design warranty"],
              plainEnglish: "Some contracts make the contractor warrant not just workmanship but also that the design will work. Particularly common in design-build, EPC, and turnkey contracts.",
              whyItMatters: "If you're not the designer, exclude design warranty. You shouldn't be on the hook for an architect's spec.",
              category: .riskAllocation),

        .init(id: "best-efforts",
              term: "Best Efforts",
              aliases: ["best endeavors"],
              plainEnglish: "An obligation standard that's higher than 'reasonable efforts' but lower than absolute. Courts interpret it variably; in practice it means 'take significant steps even at a loss'.",
              whyItMatters: "Avoid 'best efforts' language in your obligations. 'Reasonable efforts' or 'good-faith efforts' is the safer floor.",
              category: .general),

        .init(id: "default-cure-period",
              term: "Default & Cure Period",
              aliases: ["cure", "right to cure"],
              plainEnglish: "When you breach, the other side must give written notice and a defined cure period (often 7-15 days) to fix the breach before they can terminate. Without a cure period, a single breach is grounds for termination.",
              whyItMatters: "Insist on a 10+ day cure period. Catastrophes that look like default at 9am often look fixable by 5pm.",
              category: .scopeAndChange),

        .init(id: "arbitration",
              term: "Arbitration",
              aliases: ["binding arbitration", "AAA arbitration"],
              plainEnglish: "Private dispute resolution where a neutral arbitrator (or panel) issues a binding decision. Faster than courts, narrower discovery, very limited appeal. Often required by AIA and ConsensusDocs forms.",
              whyItMatters: "Cheaper for small disputes; expensive for large ones (you pay the arbitrator's hourly rate). Choose mediation-then-arbitration to filter out small claims.",
              category: .dispute),

        .init(id: "mediation",
              term: "Mediation",
              aliases: ["non-binding mediation"],
              plainEnglish: "Facilitated negotiation with a neutral mediator who helps both sides reach a settlement. Non-binding — either side can walk and proceed to arbitration or court.",
              whyItMatters: "Cheap and fast (a 1-day session). Insist on mediation as a precondition to litigation; resolves ~70% of disputes before they escalate.",
              category: .dispute),

        .init(id: "audit-rights",
              term: "Audit Rights",
              aliases: ["right to audit"],
              plainEnglish: "Lets the owner / GC inspect your books, T&M time records, supplier invoices, and other backup. Usually limited to T&M and cost-plus work and capped to a number of years post-completion.",
              whyItMatters: "Cap audit rights to 2-3 years post-completion and exclude lump-sum work. Open-ended audits invite fishing expeditions.",
              category: .general),

        .init(id: "stop-work-order",
              term: "Stop Work Order",
              aliases: ["stop notice"],
              plainEnglish: "A written direction from the owner or GC to halt all or part of the work. Usually entitles you to time extension and idle-cost compensation. Open-ended stops can cripple cash flow.",
              whyItMatters: "Document your idle costs (labor, equipment, supervision) from day 1 of any stop. Cap the duration after which you can terminate for owner default.",
              category: .scopeAndChange),

        .init(id: "schedule-baseline",
              term: "Baseline Schedule",
              aliases: ["baseline", "approved schedule"],
              plainEnglish: "The accepted project schedule against which delays and time extensions are measured. The contract usually requires you to submit it within 30 days and update it monthly.",
              whyItMatters: "Get the baseline approved fast. Until it's approved, the owner can dispute every delay claim by saying 'that's not the baseline'.",
              category: .timing),

        .init(id: "critical-path",
              term: "Critical Path",
              aliases: ["cpm", "longest path"],
              plainEnglish: "The sequence of dependent activities that determines the project's completion date. Anything on the critical path that slips, slips the project. Time-extension claims usually require proof that the delay impacted the critical path.",
              whyItMatters: "Run weekly schedule reviews. If you don't track the critical path, you can't prove a delay impacted it — and you can't recover the time.",
              category: .timing),

        .init(id: "concurrent-delay",
              term: "Concurrent Delay",
              aliases: ["concurrent"],
              plainEnglish: "Two delays happening at the same time — one your fault, one the owner's. Most jurisdictions deny BOTH parties damages during the concurrent period; you get time but no money.",
              whyItMatters: "Concurrent delay is the most common defense to your delay claim. Document the timeline carefully so you can isolate the periods of pure owner-caused delay.",
              category: .timing),

        .init(id: "subrogation-waiver",
              term: "Waiver of Subrogation",
              aliases: ["subrogation waiver"],
              plainEnglish: "Mutual agreement that neither party's insurer can sue the other party to recover what they paid out. Standard on commercial property and builder's risk policies.",
              whyItMatters: "Confirm your policy permits subrogation waivers. If your insurer doesn't allow it, you may breach by signing the contract.",
              category: .insurance),

        .init(id: "builders-risk",
              term: "Builder's Risk Insurance",
              aliases: ["course of construction insurance", "coc"],
              plainEnglish: "Property insurance covering the project itself during construction. Usually carried by the owner or GC, names everyone with a financial interest as additional insureds.",
              whyItMatters: "Confirm who carries it and what's covered. Theft of materials before installation, water damage, and fire are the big claims.",
              category: .insurance),

        .init(id: "contract-value",
              term: "Contract Value",
              aliases: ["contract sum", "contract price"],
              plainEnglish: "The total agreed price for the work, before change orders. Used as the baseline for retainage, performance bond face value, and many liability cap calculations.",
              whyItMatters: "Distinguish base contract value from final value (after COs). Many caps reset on each CO — read carefully.",
              category: .payment),

        .init(id: "as-built-drawings",
              term: "As-Built Drawings",
              aliases: ["as-builts", "record drawings"],
              plainEnglish: "Drawings that reflect what was actually built, including all field changes, deviations, and concealed conditions. Required for closeout and for the owner's future maintenance.",
              whyItMatters: "Track field changes daily, not at the end. Reconstructing as-builts from memory three months after substantial completion is a nightmare.",
              category: .general),

        .init(id: "schedule-of-submittals",
              term: "Schedule of Submittals",
              aliases: ["submittal log"],
              plainEnglish: "A list of all the shop drawings, product data, samples, and certifications you have to submit for approval before fabrication or installation. Owner approval timelines are often baked into the contract.",
              whyItMatters: "Track submittal turnaround. Slow approvals are a documented cause of delay if you have a clean log.",
              category: .scopeAndChange),

        .init(id: "warranty-call-back",
              term: "Warranty Call-Back",
              aliases: ["call-back"],
              plainEnglish: "An owner request during the warranty period for you to return and fix something. Can be legitimate (your defect) or scope creep (something you weren't responsible for).",
              whyItMatters: "Write 'warranty call-back review' into your QA process. Don't reflexively send a crew — investigate first whether it's actually warranty work.",
              category: .general),

        .init(id: "consequential-vs-direct",
              term: "Direct vs Consequential Damages",
              aliases: ["direct damages", "actual damages"],
              plainEnglish: "Direct damages = the immediate, predictable cost of fixing the breach (replace the wrong panel, pay for redo). Consequential = downstream losses (lost rent because the building can't open). Without a waiver, both are recoverable.",
              whyItMatters: "Always demand a mutual consequential-damages waiver. Direct damages are large enough; consequentials can dwarf the contract value.",
              category: .riskAllocation),

        .init(id: "sole-discretion",
              term: "Sole Discretion",
              aliases: ["in their sole discretion"],
              plainEnglish: "Phrase meaning 'the named party can decide for any reason or no reason'. Highly one-sided — courts generally enforce these unless the use is so arbitrary it violates good faith.",
              whyItMatters: "Push to replace 'sole discretion' with 'reasonable discretion' or with objective criteria. 'Sole discretion' on payment timing or change-order acceptance is dangerous.",
              category: .general),

        .init(id: "good-faith-and-fair-dealing",
              term: "Good Faith and Fair Dealing",
              aliases: ["good faith"],
              plainEnglish: "An implied obligation in every contract (in most jurisdictions) that neither party will act to deny the other the benefit of the bargain. Doesn't add new obligations — but bars sneaky behavior.",
              whyItMatters: "Knowing this exists helps in disputes — even when no clause covers a behavior, 'good faith' may.",
              category: .general),

        .init(id: "jurisdiction-and-venue",
              term: "Jurisdiction & Venue",
              aliases: ["governing law and venue"],
              plainEnglish: "Where lawsuits must be filed (venue) and which state's law governs (jurisdiction). Big deal because these change everything from lien deadlines to enforceability of clauses.",
              whyItMatters: "Local-to-you venue saves enormous travel and out-of-state counsel costs in a dispute. Try to keep both at home.",
              category: .dispute),
    ]
}
