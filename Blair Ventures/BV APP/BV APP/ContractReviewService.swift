// ContractReviewService.swift
// Aski IQ — AI-powered contract review using the ai-proxy Edge Function.
//
// WHAT IT DOES
// Takes a contract's text (pasted or extracted from PDF) plus its
// metadata (type, value, counterparty), prompts Claude through ai-proxy
// to identify the material clauses, and returns a structured response:
//
//   { summary, risk_score, risk_summary, clauses: [...] }
//
// Each clause includes original verbatim text, plain-English summary,
// and a risk flag with explanation. The result is persisted into
// `contract_clauses` (replacing prior AI-generated clauses for that
// contract) and the parent Contract is updated with the overall risk
// score + AI review timestamp.
//
// COST GOVERNANCE
// All calls go through `AIProxyClient` which is bound to the per-tenant
// caps + rate limits we built. A "deep review" mode forces sonnet for
// nuanced analysis; the default lightweight mode uses haiku. The user-
// facing UI labels the cost difference so admins can choose consciously.
//
// MODELS CHOSEN
//   Lightweight (default): claude-haiku-4-5-20251001 — ~$0.005-0.02/review
//   Deep                  : claude-sonnet-4-5         — ~$0.05-0.20/review
//
// MODEL ID NOTE
// An earlier version pinned the deep model to a non-existent
// `claude-sonnet-4-6-20251001` snapshot and Anthropic rejected the
// call with `not_found_error`. Switched to the unversioned alias
// `claude-sonnet-4-5` which always resolves to the current 4.5
// snapshot — no code change needed when a new dated build ships.
//
// ROBUSTNESS
// Claude is asked to return strict JSON. If the response can't be
// parsed, we fall back to surfacing the raw text in a plain-text
// summary clause so the user isn't left empty-handed.

import Foundation

@MainActor
final class ContractReviewService {

    static let shared = ContractReviewService()
    private init() {}

    enum ReviewMode {
        case lightweight  // haiku — fast + cheap
        case deep         // sonnet — better risk analysis

        var modelName: String {
            switch self {
            case .lightweight: return "claude-haiku-4-5-20251001"
            // Use the unversioned alias — Anthropic returned 404 on
            // the previously-pinned `claude-sonnet-4-6-20251001`
            // snapshot. The alias resolves to the latest 4.5 build.
            case .deep:        return "claude-sonnet-4-5"
            }
        }

        /// Output budget. Original values (2,500 / 4,000) were too
        /// tight — real-world reviews of multi-clause documents got
        /// truncated mid-JSON, which surfaced as parse failures even
        /// though Claude was producing valid output. Raised so the
        /// structured response always lands intact. Cost impact:
        /// Haiku ~+$0.008/call, Sonnet ~+$0.06/call — well within the
        /// per-tenant caps and still inside the "Quick" / "Deep" cost
        /// quotes in the UI.
        var maxTokens: Int {
            switch self {
            case .lightweight: return 4_500
            case .deep:        return 8_000
            }
        }

        var displayName: String {
            switch self {
            case .lightweight: return "Quick review"
            case .deep:        return "Deep review"
            }
        }

        /// Rough order-of-magnitude cost note for the UI confirmation.
        var costNote: String {
            switch self {
            case .lightweight: return "~$0.01–0.02"
            case .deep:        return "~$0.05–0.20"
            }
        }
    }

    /// Top-level result from a review call. Persisted as: clauses written
    /// to `contract_clauses`, summary + risk written back to the parent
    /// Contract, AND the structured fields in `extractedFields` are merged
    /// into the parent Contract so the Summary tab fills in automatically.
    struct ReviewResult: Codable {
        let summary: String
        let riskScore: RiskLevel
        let riskSummary: String
        let clauses: [ExtractedClause]
        /// Structured field extraction. All fields nullable — AI only
        /// fills what it can find in the document. Service-side merge
        /// rule: only update the contract field if AI returned a value
        /// AND the contract field is currently nil/empty (so manual
        /// edits and prior-review extractions are never overwritten).
        let extractedFields: ExtractedFields?

        enum CodingKeys: String, CodingKey {
            case summary
            case riskScore       = "risk_score"
            case riskSummary     = "risk_summary"
            case clauses
            case extractedFields = "extracted_fields"
        }
    }

    /// Structured fields the AI extracts from the document and pushes
    /// into the parent Contract record. Mirrors the shape Claude is
    /// asked to return in `extracted_fields`. All optional — the
    /// service only writes through values that are non-nil.
    struct ExtractedFields: Codable {
        let paymentTerms:       String?      // e.g. "Net 30", "50% mobilization, 50% completion"
        let retainagePercent:   Double?      // e.g. 10.0 for 10%
        let warrantyPeriodDays: Int?
        let governingLaw:       String?      // jurisdiction (state / province / country)
        let disputeResolution:  String?      // "mediation" | "arbitration" | "courts" | freeform
        let insuranceRequired:  Bool?
        let bondRequired:       Bool?
        let effectiveDate:      String?      // ISO YYYY-MM-DD
        let expiryDate:         String?
        let executedDate:       String?
        let contractValue:      Double?
        let counterpartyName:   String?
        /// Payment milestones found in the contract (e.g. "50% on
        /// mobilization", "20% at substantial completion"). Each
        /// becomes a `contract_milestones` row with type=payment_due
        /// when the service merges the result.
        let paymentMilestones:  [PaymentMilestone]?
        /// Insurance / bond requirements stated in the contract (e.g.
        /// "Contractor shall carry $5M CGL"). Each becomes a
        /// `compliance_documents` row flagged `is_requirement_only`.
        let complianceRequirements: [ComplianceRequirement]?

        enum CodingKeys: String, CodingKey {
            case paymentTerms           = "payment_terms"
            case retainagePercent       = "retainage_percent"
            case warrantyPeriodDays     = "warranty_period_days"
            case governingLaw           = "governing_law"
            case disputeResolution      = "dispute_resolution"
            case insuranceRequired      = "insurance_required"
            case bondRequired           = "bond_required"
            case effectiveDate          = "effective_date"
            case expiryDate             = "expiry_date"
            case executedDate           = "executed_date"
            case contractValue          = "contract_value"
            case counterpartyName       = "counterparty_name"
            case paymentMilestones      = "payment_milestones"
            case complianceRequirements = "compliance_requirements"
        }
    }

    /// One scheduled payment milestone Claude found in the contract.
    /// At least ONE of `date` or `triggerEvent` should be set. When
    /// only triggerEvent is given (e.g. "on substantial completion"),
    /// the service still creates the milestone but with a placeholder
    /// future date so it surfaces on the user's task list — the user
    /// edits the actual date when the trigger event lands.
    struct PaymentMilestone: Codable {
        let title:        String?       // e.g. "First progress payment"
        let date:         String?       // ISO YYYY-MM-DD (if explicit calendar date)
        let triggerEvent: String?       // e.g. "substantial completion", "delivery + 30 days"
        let amount:       Double?       // dollar amount, or nil if percentage-based
        let percentage:   Double?       // e.g. 50.0 for 50%
        let description:  String?

        enum CodingKeys: String, CodingKey {
            case title, date, amount, percentage, description
            case triggerEvent = "trigger_event"
        }
    }

    /// One insurance or bond requirement stated in the contract.
    /// Becomes a `compliance_documents` row with `is_requirement_only=true`.
    struct ComplianceRequirement: Codable {
        let kind:           String       // "insurance" | "bond"
        let documentType:   String       // matches ComplianceDocumentType raw values
        let minimumLimit:   Double?      // minimum coverage / face value the contract demands
        let aggregateLimit: Double?
        let notes:          String?      // additional clause language (e.g. "named additional insured", "primary and non-contributory")

        enum CodingKeys: String, CodingKey {
            case kind, notes
            case documentType   = "document_type"
            case minimumLimit   = "minimum_limit"
            case aggregateLimit = "aggregate_limit"
        }
    }

    /// Shape Claude is asked to return per clause. Mirrors `ContractClause`
    /// but lighter — no IDs, no contract linkage, no sync state.
    struct ExtractedClause: Codable {
        let kind: String
        let title: String?
        let originalText: String?
        let plainEnglish: String?
        let riskLevel: String?
        let riskExplanation: String?

        enum CodingKeys: String, CodingKey {
            case kind, title
            case originalText    = "original_text"
            case plainEnglish    = "plain_english"
            case riskLevel       = "risk_level"
            case riskExplanation = "risk_explanation"
        }
    }

    enum ReviewError: Error, LocalizedError {
        case noTextProvided
        case proxy(AIProxyClient.AIProxyError)
        case parseFailed(String)

        var errorDescription: String? {
            switch self {
            case .noTextProvided:
                return "Paste or upload contract text first."
            case .proxy(let e):
                return e.userMessage
            case .parseFailed(let s):
                return "AI returned an unexpected format: \(s)"
            }
        }
    }

    // MARK: - Public entry points

    /// Run an AI review on the given contract. On success:
    ///   * the returned ReviewResult is wired into the AppStore
    ///     (clauses replace prior AI clauses, parent contract gets
    ///     riskScore / riskSummary / aiReviewStatus updated)
    ///   * the caller can show the result in the AI review sheet
    @discardableResult
    func review(
        contract: Contract,
        contractText: String,
        mode: ReviewMode,
        in store: AppStore
    ) async throws -> ReviewResult {
        let trimmed = contractText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ReviewError.noTextProvided }

        // Mark the contract as in-flight so the UI can show a spinner
        // even if the user navigates away while the call runs.
        var inflight = contract
        inflight.aiReviewStatus = .reviewing
        store.upsertContract(inflight)

        let payload = buildPayload(
            contract:       contract,
            contractText:   trimmed,
            mode:           mode,
            companyName:    store.client(id: contract.counterpartyID ?? UUID())?.name
                            ?? AppSettings.shared.companyName
        )

        let result: ReviewResult
        switch await AIProxyClient.shared.send(payload: payload) {
        case .failure(let err):
            // Mark the review as failed so the UI shows the error state.
            var failed = contract
            failed.aiReviewStatus = .failed
            store.upsertContract(failed)
            throw ReviewError.proxy(err)

        case .success(let data):
            do {
                result = try Self.parseAnthropicResponse(data: data)
            } catch {
                var failed = contract
                failed.aiReviewStatus = .failed
                store.upsertContract(failed)
                throw ReviewError.parseFailed(error.localizedDescription)
            }
        }

        // ── 1. Append clauses (deduped) ──────────────────────────
        // Re-reviewing the same doc OR reviewing an amendment / later
        // draft should ADD to the clause set, not wipe it. Deduping by
        // (clause_kind + verbatim original_text) prevents the same
        // clause showing up twice on a re-run.
        let baseOrder = store.clauses(forContract: contract.id)
            .map { $0.displayOrder }.max().map { $0 + 1 } ?? 0
        let clauses = result.clauses.enumerated().map { (idx, ec) in
            ContractClause(
                id:               UUID(),
                companyID:        store.currentCompanyID,
                contractID:       contract.id,
                clauseKind:       ClauseKind(rawValue: ec.kind) ?? .other,
                title:            ec.title,
                originalText:     ec.originalText,
                plainEnglish:     ec.plainEnglish,
                riskLevel:        ec.riskLevel.flatMap(RiskLevel.init(rawValue:)),
                riskExplanation:  ec.riskExplanation,
                pageReference:    nil,
                displayOrder:     baseOrder + idx,
                source:           "ai",
                createdAt:        Date(),
                syncStatus:       .pending,
                isDeleted:        false
            )
        }
        store.appendAIClauses(for: contract.id, with: clauses)

        // ── 2. Merge structured fields into the contract ─────────
        // Only update a field when AI returned a value AND the contract
        // doesn't already have one. This way:
        //   • First review fills in empty fields automatically
        //   • Manual edits are never overwritten
        //   • Reviewing a second document adds info the first didn't have,
        //     without clobbering what the first already established
        var updated = contract
        Self.mergeExtractedFields(result.extractedFields, into: &updated)

        // ── 2a. Auto-create payment milestones (deduped) ────────
        if let milestones = result.extractedFields?.paymentMilestones {
            Self.appendPaymentMilestones(milestones, for: contract.id, in: store)
        }

        // ── 2b. Auto-create compliance requirements (deduped) ──
        if let reqs = result.extractedFields?.complianceRequirements {
            Self.appendComplianceRequirements(reqs, for: contract.id, in: store)
        }

        // Risk score + summary always reflect the latest review (latest
        // assessment of the *current* contract state). Prior review's
        // summary is preserved in the notes block below for audit.
        updated.riskScore       = result.riskScore
        updated.riskSummary     = result.riskSummary
        updated.aiReviewStatus  = .reviewed
        updated.aiReviewedAt    = Date()

        // ── 3. Append a dated AI summary block to notes ─────────
        // Multiple reviews stack chronologically so the user can see the
        // history of what AI thought at each pass. Doesn't touch the
        // user's free-text notes.
        updated.notes = Self.appendAISummaryNote(
            existing: updated.notes,
            summary:  result.summary,
            risk:     result.riskScore,
            riskNote: result.riskSummary,
            on:       Date()
        )

        store.upsertContract(updated)

        return result
    }

    // MARK: - Merge helpers

    /// Updates a contract in place with values from `extracted`. Only
    /// fills fields that are currently nil/empty — never overwrites.
    static func mergeExtractedFields(
        _ extracted: ExtractedFields?,
        into contract: inout Contract
    ) {
        guard let f = extracted else { return }

        // String fields: fill if empty/nil.
        if (contract.paymentTerms ?? "").isEmpty,
           let v = f.paymentTerms?.trimmedNilIfEmpty() {
            contract.paymentTerms = v
        }
        if (contract.governingLaw ?? "").isEmpty,
           let v = f.governingLaw?.trimmedNilIfEmpty() {
            contract.governingLaw = v
        }
        if (contract.disputeResolution ?? "").isEmpty,
           let v = f.disputeResolution?.trimmedNilIfEmpty() {
            contract.disputeResolution = v
        }
        if contract.counterpartyName.isEmpty || contract.counterpartyName == "—",
           let v = f.counterpartyName?.trimmedNilIfEmpty() {
            contract.counterpartyName = v
        }

        // Numeric / typed fields: fill if currently nil.
        if contract.retainagePercent == nil,
           let pct = f.retainagePercent {
            contract.retainagePercent = Decimal(pct)
        }
        if contract.warrantyPeriodDays == nil,
           let d = f.warrantyPeriodDays {
            contract.warrantyPeriodDays = d
        }
        if contract.contractValue == nil,
           let v = f.contractValue {
            contract.contractValue = Decimal(v)
        }

        // Bools: only flip a `false` to `true` if AI affirmatively says
        // true. We never flip `true` back to `false` — those flags
        // typically encode "this contract requires X" and AI not
        // finding a reference doesn't mean the requirement isn't there.
        if let req = f.insuranceRequired, req == true { contract.insuranceRequired = true }
        if let req = f.bondRequired,      req == true { contract.bondRequired      = true }

        // Dates: parse YYYY-MM-DD; fill if currently nil.
        if contract.effectiveDate == nil,
           let d = Self.parseDate(f.effectiveDate) {
            contract.effectiveDate = d
        }
        if contract.expiryDate == nil,
           let d = Self.parseDate(f.expiryDate) {
            contract.expiryDate = d
        }
        if contract.executedDate == nil,
           let d = Self.parseDate(f.executedDate) {
            contract.executedDate = d
        }
    }

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone   = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private static func parseDate(_ s: String?) -> Date? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
              s.lowercased() != "null" else { return nil }
        return isoDateFormatter.date(from: s)
    }

    /// Appends a dated AI summary block to the contract's notes,
    /// preserving everything that was there before. The block is
    /// machine-distinguishable via the `[AI Review · YYYY-MM-DD]`
    /// header so a future view can render history if we want.
    static func appendAISummaryNote(
        existing notes: String?,
        summary: String,
        risk: RiskLevel,
        riskNote: String,
        on date: Date
    ) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let stamp = f.string(from: date)
        let block = """
        [AI Review · \(stamp)]
        Summary: \(summary)
        Risk: \(risk.displayName) · \(riskNote)
        """
        let prior = (notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if prior.isEmpty { return block }
        return prior + "\n\n" + block
    }

    // MARK: - Auto-create milestones from AI extraction

    /// Creates contract_milestones rows for each AI-extracted payment
    /// milestone, deduped against existing rows on the contract by
    /// (title-lowercased, date) so re-running AI Review doesn't pile
    /// up duplicates. Skips entries with no usable date AND no useful
    /// trigger event — without something to anchor on, a milestone
    /// is just noise.
    static func appendPaymentMilestones(
        _ milestones: [PaymentMilestone],
        for contractID: UUID,
        in store: AppStore
    ) {
        guard !milestones.isEmpty else { return }

        // Build dedup key set from existing live milestones on this contract.
        let existing = store.milestones(forContract: contractID)
        let existingKeys: Set<String> = Set(existing.map(Self.milestoneDedupeKey(for:)))

        // For trigger-event-only milestones (no calendar date), pin to
        // a placeholder 90 days out so they show up on the user's task
        // list. The user can edit the date when the trigger lands.
        let placeholderDate = Calendar.current.date(byAdding: .day, value: 90, to: Date()) ?? Date()

        for m in milestones {
            let date: Date? = m.date.flatMap(parseDate(_:))
            // Skip rows with neither a date nor an actionable trigger
            // — without anchor info, the row is useless.
            guard date != nil || (m.triggerEvent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) else {
                continue
            }

            let title: String = {
                if let t = m.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
                if let t = m.triggerEvent?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    return "Payment: \(t)"
                }
                return "Payment milestone"
            }()
            let resolvedDate = date ?? placeholderDate

            // Build description with whatever context the AI provided.
            var descParts: [String] = []
            if let trigger = m.triggerEvent, !trigger.isEmpty, date != nil {
                // If AI gave both date and trigger, surface both.
                descParts.append("Trigger: \(trigger)")
            } else if date == nil, let trigger = m.triggerEvent {
                descParts.append("Trigger: \(trigger) (date pending — edit when event lands)")
            }
            if let pct = m.percentage { descParts.append("\(pct)% of contract") }
            if let extra = m.description?.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
                descParts.append(extra)
            }
            let descStr = descParts.isEmpty ? nil : descParts.joined(separator: " · ")

            var ms = ContractMilestone(
                contractID:    contractID,
                title:         title,
                milestoneDate: resolvedDate,
                milestoneType: .paymentDue
            )
            ms.companyID    = store.currentCompanyID
            ms.description  = descStr
            // amountDue: prefer explicit amount; otherwise derive from
            // percent × contract value if both are known.
            if let amt = m.amount {
                ms.amountDue = Decimal(amt)
            } else if let pct = m.percentage,
                      let value = store.contracts.first(where: { $0.id == contractID })?.contractValue {
                ms.amountDue = value * Decimal(pct) / 100
            }
            // Tag in notes so we know which milestones came from AI
            // (vs manual). Could move to a column later.
            ms.notes = "ai_payment_milestone:\(contractID.uuidString)"

            // Dedupe.
            let key = milestoneDedupeKey(title: ms.title, date: ms.milestoneDate)
            if existingKeys.contains(key) { continue }

            store.upsertContractMilestone(ms)
        }
    }

    private static func milestoneDedupeKey(for m: ContractMilestone) -> String {
        milestoneDedupeKey(title: m.title, date: m.milestoneDate)
    }
    private static func milestoneDedupeKey(title: String, date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "\(title.lowercased())|\(f.string(from: date))"
    }

    // MARK: - Auto-create compliance requirements from AI extraction

    /// Creates compliance_documents rows flagged `is_requirement_only`
    /// for each insurance/bond requirement the AI found in the
    /// contract. Deduped against existing requirement-only rows on
    /// the contract by (kind, document_type) so re-running AI Review
    /// doesn't duplicate.
    static func appendComplianceRequirements(
        _ reqs: [ComplianceRequirement],
        for contractID: UUID,
        in store: AppStore
    ) {
        guard !reqs.isEmpty else { return }

        // Existing requirement-only rows on this contract → dedup keys.
        let existing = store.complianceDocs(forContract: contractID)
            .filter { $0.isRequirementOnly }
        let existingKeys: Set<String> = Set(existing.map { "\($0.kind.rawValue)|\($0.documentType.rawValue)" })

        for r in reqs {
            guard let kind  = ComplianceKind(rawValue: r.kind),
                  let dtype = ComplianceDocumentType(rawValue: r.documentType) else { continue }

            let key = "\(kind.rawValue)|\(dtype.rawValue)"
            if existingKeys.contains(key) { continue }

            // Title pattern matches the manual-create flow so the row
            // looks consistent regardless of where it came from.
            let title = "\(dtype.displayName) — required by contract"

            var doc = ComplianceDocument(
                kind:         kind,
                documentType: dtype,
                title:        title
            )
            doc.companyID         = store.currentCompanyID
            doc.contractID        = contractID
            doc.coverageLimit     = r.minimumLimit.map  { Decimal($0) }
            doc.aggregateLimit    = r.aggregateLimit.map { Decimal($0) }
            doc.isRequirementOnly = true
            // expiryDate stays nil — we don't have an actual cert.
            doc.notes             = r.notes?.trimmedNilIfEmpty()

            store.upsertComplianceDocument(doc)
        }
    }

    // MARK: - Prompt construction

    private func buildPayload(
        contract:     Contract,
        contractText: String,
        mode:         ReviewMode,
        companyName:  String
    ) -> [String: Any] {
        // Keep the input bounded — Claude's context is plenty but cost
        // scales with input tokens. 30k chars ≈ 7-8k tokens, fits the
        // model with room for the response.
        let truncated = String(contractText.prefix(30_000))

        // Phase-2 deferred: tenant-customizable system prompt.
        // CompanyAIPromptService returns the admin's override when
        // present (companies.ai_prompt_overrides JSONB key
        // "contract_review"); otherwise the hard-coded baseline.
        let role = CompanyAIPromptService.shared.effectivePrompt(
            for:      .contractReview,
            fallback: systemPrompt(forCompany: companyName)
        )
        let user = userPrompt(contract: contract, text: truncated)

        return [
            "model":      mode.modelName,
            "max_tokens": mode.maxTokens,
            "system":     role,
            "messages":   [["role": "user", "content": user]]
        ]
    }

    private func systemPrompt(forCompany companyName: String) -> String {
        """
        You are a senior construction-law contract reviewer working for \
        \(companyName), a mid-sized field-operations and trades company. \
        Your job is to flag the clauses in this contract that materially \
        affect risk, payment, schedule, or scope.

        You are practical and direct. You do not hedge with "you should \
        consult an attorney" — the user already plans to. You explain \
        each clause in plain English (no legalese), then give a one-line \
        honest risk read for an owner-rep, sub, or supplier perspective.

        STRICT OUTPUT FORMAT
        Return ONLY a single JSON object, no preamble, no markdown fences, \
        with this exact shape:

        {
          "summary":      "<2-4 sentence plain-English description of the deal>",
          "risk_score":   "<low|medium|high|critical>",
          "risk_summary": "<2-4 sentence plain-English explanation of why this risk score>",
          "clauses": [
            {
              "kind":             "<one of: payment_terms, indemnity, dispute_resolution, warranty, termination, change_orders, scope, insurance, bond, liquidated_damages, governing_law, confidentiality, intellectual_property, limitation_of_liability, force_majeure, pay_when_paid, flow_down, lien_waiver, retainage, audit_rights, assignment, notice, other>",
              "title":            "<short label, e.g. 'Pay-When-Paid', 'Liquidated Damages $5k/day'>",
              "original_text":    "<verbatim quote from the contract, ≤500 chars>",
              "plain_english":    "<2-4 sentence explanation in plain English>",
              "risk_level":       "<low|medium|high|critical>",
              "risk_explanation": "<one direct sentence on why this is or isn't a problem>"
            }
          ],
          "extracted_fields": {
            "payment_terms":         "<short string e.g. 'Net 30' or '50% mobilization, 50% completion', or null>",
            "retainage_percent":     <number e.g. 10 (meaning 10%), or null>,
            "warranty_period_days":  <integer days, or null>,
            "governing_law":         "<jurisdiction e.g. 'Alberta', 'Texas', or null>",
            "dispute_resolution":    "<'mediation' | 'arbitration' | 'courts' | other description, or null>",
            "insurance_required":    <true | false | null>,
            "bond_required":         <true | false | null>,
            "effective_date":        "<YYYY-MM-DD, or null>",
            "expiry_date":           "<YYYY-MM-DD, or null>",
            "executed_date":         "<YYYY-MM-DD, or null>",
            "contract_value":        <number in document currency, or null>,
            "counterparty_name":     "<the other party's company name as named in the contract, or null>",

            "payment_milestones": [
              {
                "title":         "<short label e.g. 'Mobilization payment', 'Substantial completion'>",
                "date":          "<YYYY-MM-DD if the contract names a specific calendar date, else null>",
                "trigger_event": "<event-based description e.g. 'on mobilization', 'at substantial completion', 'within 30 days of delivery', or null if a calendar date is given>",
                "amount":        <dollar amount of the payment if stated, else null>,
                "percentage":    <percent of contract if stated (e.g. 50 for 50%), else null>,
                "description":   "<any additional context, or null>"
              }
            ],

            "compliance_requirements": [
              {
                "kind":           "<'insurance' | 'bond'>",
                "document_type":  "<one of: general_liability, workers_comp, auto_liability, umbrella, professional_liability, pollution_liability, builders_risk, cyber_liability, directors_officers, performance_bond, payment_bond, labor_material_bond, bid_bond, maintenance_bond, license_bond, other>",
                "minimum_limit":  <minimum coverage / face value the contract requires, or null>,
                "aggregate_limit": <minimum aggregate annual limit if specified, or null>,
                "notes":          "<additional language e.g. 'named additional insured', 'primary and non-contributory', or null>"
              }
            ]
          }
        }

        Rules:
        - Identify the material clauses (typically 5-15, but as few as 0 if the document doesn't contain contract terms).
        - Focus on money, time, and risk allocation.
        - If the document is a tender, RFP, SOW, scope summary, or other document that REFERENCES contract terms but doesn't include them, return `clauses: []` and explain in the summary which terms are referenced but missing. Do NOT pad with hypothetical clauses.
        - Mark pay-when-paid / pay-if-paid as HIGH risk for subcontractors by default.
        - Mark broad indemnity (with no carve-out for the other party's negligence) as HIGH or CRITICAL.
        - Mark missing consequential-damages waiver as MEDIUM.
        - Mark retainage above 10% as MEDIUM.
        - Mark missing termination-for-cause cure period as MEDIUM.
        - Use "low" only for genuinely benign clauses.
        - Keep plain_english simple — write for someone who has never been to law school.
        - KEEP THE SUMMARY SHORT (2-4 sentences). Do not over-explain in the summary; put detail on individual clauses.
        - For extracted_fields: only fill values you can verify from the document. Use null for anything not stated. Never guess.
          * payment_terms: paraphrase concisely (e.g. "Net 30" not the full clause).
          * retainage_percent: just the number (10 means 10%).
          * Dates: prefer the most explicit form. If only "executed in 2025" is given, leave executed_date null.
          * payment_milestones: include EVERY scheduled payment the contract names. If the contract says "50% on mobilization, 25% at framing, 25% at substantial completion", emit three entries. Use empty array [] if the contract has no payment schedule (e.g. lump sum on completion).
          * compliance_requirements: include EVERY insurance/bond requirement the contract names. If the contract says "Contractor shall carry $5M CGL, $1M Auto, and provide a Performance Bond equal to 100% of contract value", emit three entries. Use empty array [] if no requirements stated.
        - Do NOT include any text outside the JSON object.
        - Do NOT use markdown formatting inside string values (no **, no #, no bullets).
        """
    }

    private func userPrompt(contract: Contract, text: String) -> String {
        let valStr: String
        if let v = contract.contractValue {
            let f = NumberFormatter()
            f.numberStyle = .currency
            f.maximumFractionDigits = 0
            valStr = f.string(from: NSDecimalNumber(decimal: v)) ?? "$\(v)"
        } else { valStr = "not specified" }

        return """
        Contract type:    \(contract.contractType.displayName)
        Title:            \(contract.title)
        Counterparty:     \(contract.counterpartyName)
        Counterparty role: \(contract.counterpartyType?.displayName ?? "not specified")
        Contract value:   \(valStr)

        REVIEW PERSPECTIVE
        \(reviewPerspective(for: contract))

        ── Contract text ──
        \(text)
        """
    }

    /// The reviewer's stance changes based on which side of the contract
    /// our company sits on. An owner-prime contract = we're the contractor;
    /// a sub contract = we're the GC; a supply contract = we're the buyer.
    private func reviewPerspective(for contract: Contract) -> String {
        switch contract.contractType {
        case .ownerPrime:
            return "We (the company) are the CONTRACTOR. Flag clauses that shift owner risk onto us."
        case .subcontractor:
            return "We are the GENERAL CONTRACTOR hiring a sub. Flag where the sub has not assumed enough flow-down risk."
        case .materialPurchase:
            return "We are the BUYER. Flag late-delivery liability, supplier remedy caps, and warranty gaps."
        case .nda:
            return "Standard mutual NDA review. Flag overly long terms (>5y) and broad definitions of confidential information."
        case .msa, .sow:
            return "Master agreement / SOW under it. Flow-down terms and termination rights matter most."
        case .jointVenture:
            return "We are an EQUAL PARTNER. Flag asymmetric profit splits, capital-call obligations, and unilateral termination rights."
        case .consulting:
            return "We are a consulting buyer or seller. Flag IP ownership, deliverable acceptance, and scope-creep risk."
        case .other:
            return "Generic contract review."
        }
    }

    // MARK: - Response parsing

    /// Parses the Anthropic response Data into a ReviewResult. Handles
    /// the wrapping (Anthropic returns `{ content: [{ type: "text",
    /// text: "<json>" }, ...] }`) and unwraps the inner JSON string.
    static func parseAnthropicResponse(data: Data) throws -> ReviewResult {
        // 1. Anthropic envelope: handle both `content[0].text` (the
        //    happy path) and the error envelope `{"error": {...}}` so
        //    Claude's own complaints surface to the user rather than
        //    being swallowed.
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw NSError(domain: "ContractReview", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Empty or non-JSON response from AI service."])
        }
        if let errObj = json["error"] as? [String: Any],
           let msg = errObj["message"] as? String {
            throw NSError(domain: "ContractReview", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "AI service error: \(msg)"])
        }
        guard
            let content = json["content"] as? [[String: Any]],
            let first   = content.first,
            let raw     = first["text"] as? String
        else {
            throw NSError(domain: "ContractReview", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "AI response had no text content."])
        }

        // 2. Strip markdown fences defensively.
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```",     with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 3. Tolerate prose framing around the JSON. Sometimes Claude
        //    says "Here's my analysis:" or "Hope this helps!" outside
        //    the JSON object even when the prompt forbids it. We carve
        //    out the substring from the first '{' to the matching last
        //    '}' so prose bookends don't poison the decode.
        let jsonString = Self.extractJSONObject(from: cleaned) ?? cleaned

        guard let bytes = jsonString.data(using: .utf8) else {
            throw NSError(domain: "ContractReview", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't read AI response as UTF-8."])
        }

        // 4. If decoding fails, surface the raw text (truncated) in the
        //    error so the user can see what Claude actually said. This
        //    is critical when Claude returns a refusal like "Please
        //    paste actual contract text" — that text is what the user
        //    needs to see, not "data couldn't be read".
        do {
            return try JSONDecoder().decode(ReviewResult.self, from: bytes)
        } catch {
            let preview = String(cleaned.prefix(400))
            throw NSError(domain: "ContractReview", code: 4,
                          userInfo: [NSLocalizedDescriptionKey:
                            "AI response wasn't a valid review (the model may have asked for more context). Response excerpt:\n\n\(preview)"])
        }
    }

    /// Extracts the first balanced JSON object from a string. Returns
    /// nil when there's no balanced `{...}` (in which case the caller
    /// falls back to the original string and lets the decoder fail
    /// with a helpful error). Handles nested braces but not brace-
    /// inside-string-literals (good enough for AI-generated JSON
    /// where strings rarely contain stray `{`).
    private static func extractJSONObject(from s: String) -> String? {
        guard let firstBrace = s.firstIndex(of: "{") else { return nil }
        var depth = 0
        var end: String.Index? = nil
        for i in s[firstBrace...].indices {
            let c = s[i]
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { end = i; break }
            }
        }
        guard let end else { return nil }
        return String(s[firstBrace...end])
    }
}

// MARK: - String trim helper
//
// Tiny helper used by the merge logic — trims whitespace and returns
// nil for empty / "null" / "n/a" strings the AI sometimes emits even
// though we asked for a real null. Lives here rather than a global
// utilities file because it's only useful in this AI-extraction path.

private extension String {
    func trimmedNilIfEmpty() -> String? {
        let t = self.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        let lower = t.lowercased()
        if lower == "null" || lower == "n/a" || lower == "none" { return nil }
        return t
    }
}
