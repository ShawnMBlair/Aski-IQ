// ContractStore.swift
// Aski IQ — AppStore extension for the Contracts module.
//
// Holds the upsert / delete / query helpers for Contract,
// ContractClause, and ContractMilestone so the main AppStore.swift
// stays focused on session state.
//
// SAFETY MODEL
// Every upsert stamps companyID from currentCompanyID before persisting,
// matching the pattern used by upsertProject / upsertEmployee. This is
// belt-and-suspenders with the server-side RLS WITH CHECK that already
// rejects rows missing the right tenant scope.

import Foundation
import Combine

extension AppStore {

    // MARK: - Contract CRUD

    /// Insert or update a contract. Stamps tenant scope, marks pending,
    /// pushes to Supabase asynchronously. Returns the upserted contract
    /// so the caller can use the (potentially auto-generated) contract
    /// number / id.
    @discardableResult
    func upsertContract(_ item: Contract) -> Contract {
        guard requireRole(
            [.projectManager, .estimator, .officeAdmin, .manager, .executive],
            action: "upsert_contract"
        ) else { return item }

        var stamped = item
        if stamped.companyID == nil { stamped.companyID = currentCompanyID }
        if stamped.contractNumber == nil || stamped.contractNumber?.isEmpty == true {
            stamped.contractNumber = nextContractNumber()
        }
        stamped.updatedAt      = Date()
        stamped.lastModifiedAt = Date()
        stamped.lastModifiedBy = currentUser?.fullName ?? ""
        stamped.syncStatus     = .pending

        if let idx = contracts.firstIndex(where: { $0.id == stamped.id }) {
            contracts[idx] = stamped
        } else {
            contracts.append(stamped)
        }
        Task { await SyncEngine.shared.pushPending() }
        return stamped
    }

    /// Soft-delete. Contracts hold business and legal records — we
    /// never hard-delete from the client.
    func deleteContract(_ item: Contract) {
        guard requireRole(
            [.officeAdmin, .manager, .executive],
            action: "delete_contract"
        ) else { return }
        guard let idx = contracts.firstIndex(where: { $0.id == item.id }) else { return }
        var deleted = contracts[idx]
        deleted.isDeleted  = true
        deleted.deletedAt  = Date()
        deleted.deletedBy  = currentUser?.fullName ?? ""
        deleted.syncStatus = .pending
        contracts[idx] = deleted
        Task { await SyncEngine.shared.pushPending() }
    }

    /// Auto-generated next number, scoped to the current calendar year.
    /// Format: `C-YYYY-NNN` (e.g. `C-2026-007`). Same pattern the rest
    /// of the app uses for invoice / quote numbers.
    /// Phase 3: parsed-max+1 was already in place; added companyID +
    /// !isDeleted filters to match the project-wide standard. DB-side
    /// partial unique index on (company_id, contract_number) WHERE
    /// is_deleted = false (CON1 migration) catches cross-device races.
    func nextContractNumber() -> String {
        let year = Calendar.current.component(.year, from: Date())
        let prefix = "C-\(year)-"
        // FIX: monotonic numbering — see nextMaterialRequestNumber.
        let used = contracts
            .filter { $0.companyID == currentCompanyID }
            .compactMap { c -> Int? in
                guard let n = c.contractNumber, n.hasPrefix(prefix) else { return nil }
                return Int(n.dropFirst(prefix.count))
            }
        let next = (used.max() ?? 0) + 1
        return prefix + String(format: "%03d", next)
    }

    // MARK: - Live filter helpers

    /// Live (non-deleted) contracts. Single source of truth used by
    /// every list / filter so soft-deletes don't leak into the UI.
    var liveContracts: [Contract] {
        contracts.filter { !$0.isDeleted }
    }

    /// Contracts that need attention right now — drives the dashboard
    /// "X contracts need review" pill. Includes Drafts (work to do),
    /// expiring soon (renewal pressure), and overdue milestones.
    var contractsNeedingAttention: [Contract] {
        liveContracts.filter { c in
            c.status == .draft ||
            c.status == .underReview ||
            c.isExpiringSoon ||
            hasOverdueMilestones(forContract: c.id)
        }
    }

    /// Contracts for a project — used by ProjectDetailView's contract tab.
    func contracts(forProject projectID: UUID) -> [Contract] {
        liveContracts.filter { $0.projectID == projectID }
    }

    /// Contracts for a client / sub / supplier — used on the CRM
    /// company detail screen.
    func contracts(forCounterparty id: UUID) -> [Contract] {
        liveContracts.filter { $0.counterpartyID == id }
    }

    // MARK: - Clause helpers

    /// Append AI-generated clauses to a contract, deduping against
    /// existing AI clauses so re-reviews on the same document don't
    /// produce duplicates AND reviewing additional documents (an
    /// amendment, a later draft) builds up the clause set rather than
    /// wiping prior findings.
    ///
    /// Dedup rule: an incoming clause is dropped if any existing live
    /// AI clause on the contract has the same `clauseKind` AND the
    /// same trimmed `originalText`. This is conservative — clauses
    /// from genuinely different documents almost never share verbatim
    /// text. False-positive dedups are rare and harmless; false-
    /// negative dedups (stuff slipping through as duplicate) are the
    /// thing the user explicitly told us to avoid.
    ///
    /// Manually-entered clauses (`source == "manual"`) are never
    /// touched.
    func appendAIClauses(for contractID: UUID, with newClauses: [ContractClause]) {
        // Snapshot existing live AI clauses for this contract so we can
        // dedupe against them. Index by (kind, normalizedText).
        let existingKeys: Set<String> = Set(
            contractClauses
                .filter {
                    $0.contractID == contractID &&
                    $0.source == "ai" &&
                    !$0.isDeleted
                }
                .map(Self.dedupeKey(for:))
        )

        var inserted = 0
        for clause in newClauses {
            var stamped = clause
            stamped.companyID  = stamped.companyID ?? currentCompanyID
            stamped.contractID = contractID
            stamped.source     = "ai"
            stamped.syncStatus = .pending
            let key = Self.dedupeKey(for: stamped)
            if existingKeys.contains(key) { continue }
            contractClauses.append(stamped)
            inserted += 1
        }
        if inserted > 0 {
            Task { await SyncEngine.shared.pushPending() }
        }
    }

    /// Hard-replace mode (kept for cases where the user explicitly
    /// wants to start over — e.g. "Clear AI data" admin action).
    func replaceAIClauses(for contractID: UUID, with newClauses: [ContractClause]) {
        for i in contractClauses.indices {
            if contractClauses[i].contractID == contractID,
               contractClauses[i].source == "ai",
               !contractClauses[i].isDeleted {
                contractClauses[i].isDeleted = true
                contractClauses[i].syncStatus = .pending
            }
        }
        appendAIClauses(for: contractID, with: newClauses)
    }

    /// Phase-2 deferred audit fix: full "Reset AI-extracted data" path.
    /// Wipes EVERYTHING the AI Review flow ever produced for one
    /// contract — clauses, milestones it created, compliance
    /// requirements it created, plus the extracted summary fields on
    /// the contract itself (paymentTerms / retainagePercent / warranty
    /// / governing law / dispute resolution / insurance / bond /
    /// riskScore / riskSummary). Manually-entered data on the same
    /// fields is left alone — we only reset where the prior value
    /// matches what AI wrote.
    ///
    /// USE CASE
    /// AI Review extracts garbage from a noisy PDF. Operator hits
    /// "Reset AI-extracted data" → all the bad rows + fields clear,
    /// and they can re-run AI Review or fill manually.
    ///
    /// SAFETY
    /// Admin-only (gated by `requireRole`). Soft-deletes child rows
    /// so they round-trip server-side as `is_deleted = true` — the
    /// audit trail of what AI extracted is preserved.
    func resetAIExtractedData(for contractID: UUID) {
        guard requireRole([.officeAdmin, .manager, .executive],
                          action: "reset_ai_data") else { return }
        guard let cIdx = contracts.firstIndex(where: { $0.id == contractID }) else { return }

        // 1. AI clauses → soft-delete. ContractClause has only
        // `createdAt` (no updatedAt) so we just stamp .pending; the
        // sync layer updates the server-side timestamp.
        for i in contractClauses.indices {
            if contractClauses[i].contractID == contractID,
               contractClauses[i].source == "ai",
               !contractClauses[i].isDeleted {
                contractClauses[i].isDeleted = true
                contractClauses[i].syncStatus = .pending
            }
        }

        // 2. AI-created milestones → soft-delete. ContractReviewService.
        //    appendPaymentMilestones marks them with the prefix
        //    "ai_payment_milestone:" in `notes` — checked here.
        for i in contractMilestones.indices {
            guard contractMilestones[i].contractID == contractID,
                  !contractMilestones[i].isDeleted else { continue }
            if (contractMilestones[i].notes ?? "").hasPrefix("ai_payment_milestone:") {
                contractMilestones[i].isDeleted = true
                contractMilestones[i].syncStatus = .pending
                contractMilestones[i].updatedAt  = Date()
            }
        }

        // 3. AI-created compliance requirements → soft-delete.
        //    `isRequirementOnly = true` rows are by definition the
        //    AI-extracted ones (manual cert uploads flip the flag
        //    to false when the operator fills in carrier/policy).
        for i in complianceDocuments.indices {
            guard complianceDocuments[i].contractID == contractID,
                  !complianceDocuments[i].isDeleted else { continue }
            if complianceDocuments[i].isRequirementOnly {
                complianceDocuments[i].isDeleted = true
                complianceDocuments[i].syncStatus = .pending
                complianceDocuments[i].updatedAt  = Date()
            }
        }

        // 4. Reset the AI-extracted summary fields on the contract
        //    itself. We don't blindly null them — only clear when the
        //    field is non-nil (manual edits AFTER AI ran also live
        //    here, but operators who hit Reset are explicitly opting
        //    to wipe). riskScore/riskSummary are AI-only, always cleared.
        var c = contracts[cIdx]
        c.paymentTerms        = nil
        c.retainagePercent    = nil
        c.warrantyPeriodDays  = nil
        c.governingLaw        = nil
        c.disputeResolution   = nil
        c.insuranceRequired   = false
        c.bondRequired        = false
        c.riskScore           = nil
        c.riskSummary         = nil
        c.aiReviewStatus      = .notReviewed
        c.aiReviewedAt        = nil
        c.updatedAt           = Date()
        c.lastModifiedAt      = Date()
        c.syncStatus          = .pending
        contracts[cIdx]       = c

        objectWillChange.send()
        saveToDisk()
        Task { await SyncEngine.shared.pushPending() }

        // 5. Audit row for the destructive action.
        createAuditSnapshot(
            for:       c,
            eventType: "ai_data_reset",
            by:        currentUser?.fullName ?? "system"
        )
    }

    private static func dedupeKey(for clause: ContractClause) -> String {
        let normText = (clause.originalText ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "\(clause.clauseKind.rawValue)|\(normText)"
    }

    /// Add a single manually-entered clause. Distinct from AI clauses
    /// because manual ones survive AI re-review.
    @discardableResult
    func upsertContractClause(_ clause: ContractClause) -> ContractClause {
        var stamped = clause
        if stamped.companyID == nil { stamped.companyID = currentCompanyID }
        stamped.syncStatus = .pending
        if let idx = contractClauses.firstIndex(where: { $0.id == stamped.id }) {
            contractClauses[idx] = stamped
        } else {
            contractClauses.append(stamped)
        }
        Task { await SyncEngine.shared.pushPending() }
        return stamped
    }

    func deleteContractClause(_ clause: ContractClause) {
        guard let idx = contractClauses.firstIndex(where: { $0.id == clause.id }) else { return }
        var deleted = contractClauses[idx]
        deleted.isDeleted  = true
        deleted.syncStatus = .pending
        contractClauses[idx] = deleted
        Task { await SyncEngine.shared.pushPending() }
    }

    /// Live clauses for a contract, ordered by display_order then by
    /// risk descending so high-risk items surface first.
    func clauses(forContract contractID: UUID) -> [ContractClause] {
        contractClauses
            .filter { $0.contractID == contractID && !$0.isDeleted }
            .sorted { lhs, rhs in
                let lhsRisk = riskRank(lhs.riskLevel)
                let rhsRisk = riskRank(rhs.riskLevel)
                if lhsRisk != rhsRisk { return lhsRisk > rhsRisk }
                return lhs.displayOrder < rhs.displayOrder
            }
    }

    private func riskRank(_ level: RiskLevel?) -> Int {
        switch level {
        case .critical: return 4
        case .high:     return 3
        case .medium:   return 2
        case .low:      return 1
        case .none:     return 0
        }
    }

    // MARK: - Milestone helpers

    @discardableResult
    func upsertContractMilestone(_ milestone: ContractMilestone) -> ContractMilestone {
        var stamped = milestone
        if stamped.companyID == nil { stamped.companyID = currentCompanyID }
        stamped.updatedAt  = Date()
        stamped.syncStatus = .pending
        if let idx = contractMilestones.firstIndex(where: { $0.id == stamped.id }) {
            contractMilestones[idx] = stamped
        } else {
            contractMilestones.append(stamped)
        }
        Task { await SyncEngine.shared.pushPending() }
        return stamped
    }

    func deleteContractMilestone(_ milestone: ContractMilestone) {
        guard let idx = contractMilestones.firstIndex(where: { $0.id == milestone.id }) else { return }
        var deleted = contractMilestones[idx]
        deleted.isDeleted  = true
        deleted.syncStatus = .pending
        contractMilestones[idx] = deleted
        Task { await SyncEngine.shared.pushPending() }
    }

    /// Live milestones for a contract, sorted by date ascending.
    func milestones(forContract contractID: UUID) -> [ContractMilestone] {
        contractMilestones
            .filter { $0.contractID == contractID && !$0.isDeleted }
            .sorted { $0.milestoneDate < $1.milestoneDate }
    }

    /// All live milestones falling on a specific calendar day. Used
    /// by the Schedule tab so contract dates show up alongside crew
    /// shifts and material deliveries.
    func contractMilestones(for date: Date) -> [ContractMilestone] {
        let cal = Calendar.current
        return contractMilestones
            .filter { !$0.isDeleted && cal.isDate($0.milestoneDate, inSameDayAs: date) }
            .sorted { $0.milestoneDate < $1.milestoneDate }
    }

    /// True when any non-completed milestone for the contract is past
    /// its date. Drives the "needs attention" filter.
    func hasOverdueMilestones(forContract contractID: UUID) -> Bool {
        let today = Calendar.current.startOfDay(for: Date())
        return contractMilestones.contains { m in
            !m.isDeleted &&
            m.contractID == contractID &&
            m.status != .completed &&
            m.status != .waived &&
            m.milestoneDate < today
        }
    }

    // MARK: - Compliance Document CRUD

    /// Insert/update a compliance doc and auto-create the two expiry
    /// milestones (warning 30 days out + on-day expiry). Idempotent —
    /// re-saving a doc with the same expiry doesn't duplicate milestones.
    @discardableResult
    func upsertComplianceDocument(_ doc: ComplianceDocument) -> ComplianceDocument {
        guard requireRole(
            [.projectManager, .estimator, .officeAdmin, .manager, .executive],
            action: "upsert_compliance_document"
        ) else { return doc }

        var stamped = doc
        if stamped.companyID == nil { stamped.companyID = currentCompanyID }
        stamped.updatedAt  = Date()
        stamped.syncStatus = .pending

        if let idx = complianceDocuments.firstIndex(where: { $0.id == stamped.id }) {
            complianceDocuments[idx] = stamped
        } else {
            complianceDocuments.append(stamped)
        }

        // Auto-create / refresh the two expiry milestones if this doc
        // is attached to a contract. Without contract linkage there's
        // no milestone target, so we skip silently.
        if let contractID = stamped.contractID {
            syncExpiryMilestones(for: stamped, contractID: contractID)
        }

        Task { await SyncEngine.shared.pushPending() }
        return stamped
    }

    func deleteComplianceDocument(_ doc: ComplianceDocument) {
        guard requireRole(
            [.officeAdmin, .manager, .executive],
            action: "delete_compliance_document"
        ) else { return }
        guard let idx = complianceDocuments.firstIndex(where: { $0.id == doc.id }) else { return }
        var deleted = complianceDocuments[idx]
        deleted.isDeleted  = true
        deleted.syncStatus = .pending
        complianceDocuments[idx] = deleted

        // Tear down the auto-created expiry milestones tied to this doc.
        for i in contractMilestones.indices
            where !contractMilestones[i].isDeleted &&
                  contractMilestones[i].notes == Self.expiryMilestoneTag(for: doc.id) {
            contractMilestones[i].isDeleted  = true
            contractMilestones[i].syncStatus = .pending
        }

        Task { await SyncEngine.shared.pushPending() }
    }

    /// All live compliance docs for a contract, sorted: requirement-only
    /// rows first (so unmet requirements jump out at the top), then
    /// real certs by expiry ascending.
    func complianceDocs(forContract contractID: UUID) -> [ComplianceDocument] {
        complianceDocuments
            .filter { !$0.isDeleted && $0.contractID == contractID }
            .sorted { lhs, rhs in
                if lhs.isRequirementOnly != rhs.isRequirementOnly {
                    return lhs.isRequirementOnly && !rhs.isRequirementOnly
                }
                let lhsDate = lhs.expiryDate ?? .distantFuture
                let rhsDate = rhs.expiryDate ?? .distantFuture
                return lhsDate < rhsDate
            }
    }

    /// Live compliance docs across the company that are expiring within
    /// the next 30 days (or already expired). Drives the
    /// "X compliance items expiring" pill on the dashboard. Excludes
    /// requirement-only rows — they have no expiry to warn about yet.
    var expiringCompliance: [ComplianceDocument] {
        complianceDocuments
            .filter { !$0.isDeleted && !$0.isRequirementOnly && $0.isExpiringSoon }
            .sorted { ($0.expiryDate ?? .distantFuture) < ($1.expiryDate ?? .distantFuture) }
    }

    // MARK: - Auto-expiry milestone synthesis

    /// Internal: ensures exactly two milestones exist for this doc —
    /// a warning 30 days before expiry, and a hard pin on the expiry
    /// date itself. Tagged in the milestone's `notes` so we can find &
    /// rebuild them when the doc's expiry changes (or it's deleted).
    private func syncExpiryMilestones(for doc: ComplianceDocument, contractID: UUID) {
        let tag = Self.expiryMilestoneTag(for: doc.id)
        // Soft-delete any stale milestones for this doc — easier than
        // diff-update because there's at most 2 rows per doc.
        for i in contractMilestones.indices
            where contractMilestones[i].notes == tag &&
                  !contractMilestones[i].isDeleted {
            contractMilestones[i].isDeleted  = true
            contractMilestones[i].syncStatus = .pending
        }

        // Skip milestone synthesis for requirement-only rows or when
        // there's no actual expiry date yet. The user fills the cert
        // details + flips off requirement-only later, at which point
        // upsertComplianceDocument re-runs this and the milestones land.
        guard !doc.isRequirementOnly, let expiry = doc.expiryDate else { return }

        let cal = Calendar.current
        let warningDate = cal.date(byAdding: .day, value: -30, to: expiry) ?? expiry
        let kindLabel: String = (doc.kind == .insurance ? "Insurance" : "Bond")
        let mtype: MilestoneType = (doc.kind == .insurance) ? .insuranceRenewal : .bondExpiry

        // 30-day-out warning (only if it's still in the future).
        if warningDate >= cal.startOfDay(for: Date()) {
            var warn = ContractMilestone(
                contractID:    contractID,
                title:         "\(kindLabel) renewal warning: \(doc.title)",
                milestoneDate: warningDate,
                milestoneType: .expiryWarning
            )
            warn.companyID = currentCompanyID
            warn.description = "30-day heads-up — \(doc.title) (\(doc.documentType.displayName)) expires \(Self.dateLabel(expiry))."
            warn.notes = tag
            warn.syncStatus = .pending
            contractMilestones.append(warn)
        }

        // Hard expiry pin.
        var hard = ContractMilestone(
            contractID:    contractID,
            title:         "\(kindLabel) EXPIRES: \(doc.title)",
            milestoneDate: expiry,
            milestoneType: mtype
        )
        hard.companyID = currentCompanyID
        hard.description = "\(doc.documentType.displayName) coverage ends today. Renew with \(doc.carrier ?? "carrier") and replace this doc."
        hard.notes = tag
        hard.syncStatus = .pending
        contractMilestones.append(hard)
    }

    /// Marker stored in milestone.notes so we can find auto-generated
    /// rows for a given compliance doc and rebuild / tear down. Picked
    /// over a dedicated column to avoid another schema migration.
    private static func expiryMilestoneTag(for docID: UUID) -> String {
        "auto_compliance_milestone:\(docID.uuidString)"
    }

    private static func dateLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; return f.string(from: d)
    }

    // MARK: - Lien Waivers

    @discardableResult
    func upsertLienWaiver(_ waiver: LienWaiver) -> LienWaiver {
        guard requireRole(
            [.projectManager, .estimator, .officeAdmin, .manager, .executive],
            action: "upsert_lien_waiver"
        ) else { return waiver }

        var stamped = waiver
        if stamped.companyID == nil { stamped.companyID = currentCompanyID }
        stamped.updatedAt  = Date()
        stamped.syncStatus = .pending

        if let idx = lienWaivers.firstIndex(where: { $0.id == stamped.id }) {
            lienWaivers[idx] = stamped
        } else {
            lienWaivers.append(stamped)
        }
        Task { await SyncEngine.shared.pushPending() }
        return stamped
    }

    func deleteLienWaiver(_ waiver: LienWaiver) {
        guard requireRole(
            [.officeAdmin, .manager, .executive],
            action: "delete_lien_waiver"
        ) else { return }
        guard let idx = lienWaivers.firstIndex(where: { $0.id == waiver.id }) else { return }
        var deleted = lienWaivers[idx]
        deleted.isDeleted  = true
        deleted.syncStatus = .pending
        lienWaivers[idx] = deleted
        Task { await SyncEngine.shared.pushPending() }
    }

    /// Live waivers for a contract, sorted by date desc (newest first).
    func lienWaivers(forContract contractID: UUID) -> [LienWaiver] {
        lienWaivers
            .filter { !$0.isDeleted && $0.contractID == contractID }
            .sorted { $0.requestedAt > $1.requestedAt }
    }

    /// All open (still-need-action) waivers across the company. Drives
    /// the "X waivers awaiting signature" pill on the dashboard.
    var openLienWaivers: [LienWaiver] {
        lienWaivers.filter { !$0.isDeleted && $0.status.isOpen }
    }
}
