// ContractDiffService.swift
// Aski IQ — AI-powered diff between two contract versions.
//
// WHY THIS EXISTS
// During negotiation, a sub or supplier returns a marked-up version of
// the contract. The PM has to figure out: what actually changed, which
// clauses moved in our favor / against us, and is anything material
// that we'd missed?
//
// Doing this manually is the single most painful and dangerous task
// in contract review. Miss a one-word swap on indemnity and you've
// taken on millions in liability. This service runs the comparison
// through the same `ai-proxy` Edge Function (so it's cost-controlled
// per the per-tenant caps) and returns a structured diff:
//
//   {
//     summary:       "1-paragraph: what materially changed",
//     risk_delta:    "improved | unchanged | degraded | major_shift",
//     changes: [{
//       kind:          "added | removed | modified",
//       clause_kind:   "payment_terms | indemnity | ...",
//       title:         "Short label",
//       old_text:      "verbatim from old version",
//       new_text:      "verbatim from new version",
//       explanation:   "plain-English what changed",
//       impact:        "low | medium | high | critical",
//       impact_note:   "why this matters for our side"
//     }]
//   }
//
// LIGHTWEIGHT VS DEEP
// Diff is more nuanced than first-pass review — the user typically
// runs it on contracts they've already vetted once. Default is the
// sonnet (deep) model so the analysis catches subtle word swaps. The
// haiku option is offered for very small revisions or budget runs.

import Foundation

@MainActor
final class ContractDiffService {

    static let shared = ContractDiffService()
    private init() {}

    // MARK: - Models

    /// Structured diff result. Mirrors the JSON Claude is asked to return.
    struct DiffResult: Codable {
        let summary: String
        /// `improved` = better for us; `degraded` = worse; `major_shift`
        /// = lots changed, can't compress into one direction; `unchanged`
        /// = trivial / cosmetic edits only.
        let riskDelta: RiskDelta
        let changes: [DiffChange]

        enum CodingKeys: String, CodingKey {
            case summary
            case riskDelta = "risk_delta"
            case changes
        }
    }

    enum RiskDelta: String, Codable, CaseIterable, Identifiable {
        case improved
        case unchanged
        case degraded
        case majorShift = "major_shift"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .improved:    return "Improved for us"
            case .unchanged:   return "No material change"
            case .degraded:    return "Worse for us"
            case .majorShift:  return "Major shift — needs review"
            }
        }
    }

    enum DiffChangeKind: String, Codable, CaseIterable {
        case added
        case removed
        case modified

        var displayName: String { rawValue.capitalized }
    }

    /// One discrete change. `oldText` and `newText` are nullable
    /// because pure additions have no old, pure removals have no new.
    struct DiffChange: Codable, Identifiable {
        var id: String { UUID().uuidString }
        let kind: DiffChangeKind
        let clauseKind: ClauseKind?
        let title: String
        let oldText: String?
        let newText: String?
        let explanation: String
        let impact: RiskLevel
        let impactNote: String?

        enum CodingKeys: String, CodingKey {
            case kind
            case clauseKind  = "clause_kind"
            case title
            case oldText     = "old_text"
            case newText     = "new_text"
            case explanation
            case impact
            case impactNote  = "impact_note"
        }
    }

    enum DiffMode {
        case lightweight
        case deep

        var modelName: String {
            switch self {
            case .lightweight: return "claude-haiku-4-5-20251001"
            // Same fix as ContractReviewService — the dated snapshot
            // `claude-sonnet-4-6-20251001` is a not_found_error on
            // Anthropic's API. Alias resolves to current 4.5.
            case .deep:        return "claude-sonnet-4-5"
            }
        }
        /// Raised from 3,000 / 4,500 — same reason as ContractReviewService:
        /// real-world diffs were getting truncated mid-JSON. Diff output
        /// is denser than review (verbatim old + new text per change),
        /// so headroom matters even more here.
        var maxTokens: Int {
            switch self {
            case .lightweight: return 5_000
            case .deep:        return 8_500
            }
        }
        var displayName: String {
            switch self {
            case .lightweight: return "Quick diff"
            case .deep:        return "Deep diff"
            }
        }
        var costNote: String {
            switch self {
            case .lightweight: return "~$0.01–0.03"
            case .deep:        return "~$0.08–0.25"
            }
        }
    }

    enum DiffError: Error, LocalizedError {
        case missingText
        case proxy(AIProxyClient.AIProxyError)
        case parseFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingText:
                return "Paste both the old and new contract text first."
            case .proxy(let e):
                return e.userMessage
            case .parseFailed(let s):
                return "AI returned an unexpected format: \(s)"
            }
        }
    }

    // MARK: - Run a diff

    /// Diffs two contract versions and returns a structured report.
    /// `oldText` is the previously-agreed version; `newText` is the
    /// returned / proposed version. The `contract` is used for context
    /// in the prompt — what type of contract are we reviewing — so
    /// Claude knows which side we're on.
    func diff(
        contract: Contract,
        oldText: String,
        newText: String,
        mode: DiffMode
    ) async throws -> DiffResult {
        let oldTrim = oldText.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTrim = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldTrim.isEmpty, !newTrim.isEmpty else {
            throw DiffError.missingText
        }

        let payload = buildPayload(
            contract: contract,
            oldText:  oldTrim,
            newText:  newTrim,
            mode:     mode
        )

        switch await AIProxyClient.shared.send(payload: payload) {
        case .failure(let err):
            throw DiffError.proxy(err)
        case .success(let data):
            do {
                return try Self.parseAnthropicResponse(data: data)
            } catch {
                throw DiffError.parseFailed(error.localizedDescription)
            }
        }
    }

    // MARK: - Prompt construction

    private func buildPayload(
        contract: Contract,
        oldText:  String,
        newText:  String,
        mode:     DiffMode
    ) -> [String: Any] {
        // Each side capped to 15k chars (~3.7k tokens). Total input
        // budget ~30k chars / 7.5k tokens leaves room for a meaty
        // structured response.
        let oldClipped = String(oldText.prefix(15_000))
        let newClipped = String(newText.prefix(15_000))

        let systemPrompt = """
        You are a senior construction-law contract reviewer working for \
        \(AppSettings.shared.companyName), a mid-sized field-operations and \
        trades company. The user gives you two versions of a contract — \
        an OLD version (prior agreement / their last sent draft) and a \
        NEW version (counterparty's redline / current proposal).

        Your job is to identify every MATERIAL change between the two and \
        flag the ones that affect risk, payment, schedule, or scope.

        You are practical and direct. Cosmetic edits (whitespace, \
        capitalization, formatting) should be IGNORED. Only flag changes \
        that move the needle for the contractor's exposure or rights.

        REVIEW PERSPECTIVE
        \(reviewPerspective(for: contract))

        STRICT OUTPUT FORMAT
        Return ONLY a single JSON object, no preamble, no markdown fences, \
        with this exact shape:

        {
          "summary":     "<1-paragraph plain-English summary of what materially changed>",
          "risk_delta":  "<improved|unchanged|degraded|major_shift>",
          "changes": [
            {
              "kind":         "<added|removed|modified>",
              "clause_kind":  "<one of: payment_terms, indemnity, dispute_resolution, warranty, termination, change_orders, scope, insurance, bond, liquidated_damages, governing_law, confidentiality, intellectual_property, limitation_of_liability, force_majeure, pay_when_paid, flow_down, lien_waiver, retainage, audit_rights, assignment, notice, other>",
              "title":        "<short label, e.g. 'Indemnity broadened to cover their negligence'>",
              "old_text":     "<verbatim from OLD, ≤500 chars; null when kind == 'added'>",
              "new_text":     "<verbatim from NEW, ≤500 chars; null when kind == 'removed'>",
              "explanation":  "<2-4 sentences in plain English: what changed and what it means>",
              "impact":       "<low|medium|high|critical>",
              "impact_note":  "<one direct sentence on why this matters for our side>"
            }
          ]
        }

        Rules:
        - Identify the material changes (typically 3-12, but as few as 0 if nothing material changed).
        - Skip cosmetic ones — whitespace, capitalization, formatting.
        - If the OLD or NEW text is incomplete (e.g. only a header / table of contents / scope summary without contract terms), return `changes: []` and note that in the summary.
        - Mark added one-sided indemnity, expanded LDs, or new pay-when-paid clauses as HIGH or CRITICAL.
        - Mark removed cure periods, removed mutual waivers, or shortened notice windows as HIGH.
        - Mark scope expansions without price change as HIGH.
        - Use 'low' only for genuinely benign changes.
        - Set risk_delta to 'improved' if the net change favors us, 'degraded' if it favors them, 'major_shift' if both directions appear in significant quantity, 'unchanged' if only cosmetic edits.
        - KEEP THE SUMMARY SHORT (2-4 sentences). Detail belongs on individual changes, not in the summary.
        - Do NOT include any text outside the JSON object.
        - Do NOT use markdown formatting inside string values.
        """

        let user = """
        Contract type:    \(contract.contractType.displayName)
        Title:            \(contract.title)
        Counterparty:     \(contract.counterpartyName)

        ── OLD VERSION ──
        \(oldClipped)

        ── NEW VERSION ──
        \(newClipped)
        """

        // Phase-2 deferred: tenant-customizable diff prompt. Falls
        // back to the locally-built systemPrompt when no override.
        let resolvedSystem = CompanyAIPromptService.shared.effectivePrompt(
            for:      .contractDiff,
            fallback: systemPrompt
        )
        return [
            "model":      mode.modelName,
            "max_tokens": mode.maxTokens,
            "system":     resolvedSystem,
            "messages":   [["role": "user", "content": user]]
        ]
    }

    private func reviewPerspective(for contract: Contract) -> String {
        switch contract.contractType {
        case .ownerPrime:
            return "We are the CONTRACTOR. Flag changes that shift owner risk onto us."
        case .subcontractor:
            return "We are the GENERAL CONTRACTOR hiring a sub. Flag where the sub has reduced their risk exposure to us."
        case .materialPurchase:
            return "We are the BUYER. Flag changes to delivery liability, supplier remedy caps, warranty, or pricing terms."
        case .nda:
            return "Standard NDA review. Flag broadened definitions of confidential info, lengthened terms, or sneaked-in non-competes."
        case .msa, .sow:
            return "Master agreement / SOW under it. Flag changes to flow-down or termination rights."
        case .jointVenture:
            return "We are an EQUAL PARTNER. Flag asymmetric profit splits, capital calls, or unilateral termination changes."
        case .consulting:
            return "Consulting buyer or seller. Flag IP ownership, deliverable acceptance, and scope-creep risk."
        case .other:
            return "Generic contract diff."
        }
    }

    // MARK: - Response parsing

    static func parseAnthropicResponse(data: Data) throws -> DiffResult {
        // Same robustness pattern as ContractReviewService — handle
        // Anthropic error envelope, strip markdown fences, extract the
        // first balanced JSON object even if Claude wrapped it in
        // prose, and surface the raw response in the error so refusal
        // messages reach the user.
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw NSError(domain: "ContractDiff", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Empty or non-JSON response from AI service."])
        }
        if let errObj = json["error"] as? [String: Any],
           let msg = errObj["message"] as? String {
            throw NSError(domain: "ContractDiff", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "AI service error: \(msg)"])
        }
        guard
            let content = json["content"] as? [[String: Any]],
            let first   = content.first,
            let raw     = first["text"] as? String
        else {
            throw NSError(domain: "ContractDiff", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "AI response had no text content."])
        }

        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```",     with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonString = Self.extractJSONObject(from: cleaned) ?? cleaned

        guard let bytes = jsonString.data(using: .utf8) else {
            throw NSError(domain: "ContractDiff", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't read AI response as UTF-8."])
        }
        do {
            return try JSONDecoder().decode(DiffResult.self, from: bytes)
        } catch {
            let preview = String(cleaned.prefix(400))
            throw NSError(domain: "ContractDiff", code: 4,
                          userInfo: [NSLocalizedDescriptionKey:
                            "AI response wasn't a valid diff (the model may have asked for more context or full text). Response excerpt:\n\n\(preview)"])
        }
    }

    /// First balanced `{...}` substring. Tolerates prose around the
    /// JSON. Same helper as ContractReviewService — duplicated rather
    /// than shared because it's tiny and keeping each service self-
    /// contained avoids dragging in a Utilities file just for this.
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
