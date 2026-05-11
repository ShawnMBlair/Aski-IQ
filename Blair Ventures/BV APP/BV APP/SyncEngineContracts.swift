// SyncEngineContracts.swift
// Aski IQ — Sync paths for the Contracts module (pull + push for
// contracts, contract_clauses, contract_milestones).
//
// SHAPE
// Three pairs of pull/push functions, one per table. Each follows the
// same merge pattern used elsewhere in the engine: keep local rows
// that are .pending / .local / .failed (in-flight edits or push-rejects),
// overwrite anything else with the server's view.
//
// HOOKED UP IN
//   SyncEngine.pullAll       → call pullContracts/pullContractClauses/pullContractMilestones
//   SyncEngine.pushPending   → call pushPending* equivalents
// (Wiring lives in SyncEngine.swift; this file only defines the methods.)

import Foundation
import Combine
import Supabase

extension SyncEngine {

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Contracts (parent records)
    // ─────────────────────────────────────────────────────────────────

    func pullContracts() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, title, contract_type, status, counterparty_name: String
                let company_id: String
                let external_id, contract_number: String?
                let counterparty_type: String?
                let counterparty_id, counterparty_email: String?
                /// FIX (debug audit): decode CRM linkage.
                let opportunity_id: String?
                let project_id, parent_contract_id, quote_id, supersedes_contract_id: String?
                let contract_value: Double?
                let currency: String
                let retainage_percent: Double?
                let effective_date, expiry_date, renewal_date, executed_date, termination_date: String?
                let version: Int
                let payment_terms: String?
                let warranty_period_days: Int?
                let insurance_required, bond_required: Bool
                let governing_law, dispute_resolution: String?
                let risk_score, risk_summary, ai_review_status: String?
                let ai_reviewed_at: String?
                let primary_document_url, primary_document_name: String?
                let notes: String?
                let assigned_reviewer_id, approved_by_id: String?
                let reviewed_at, approved_at: String?
                let is_deleted: Bool
                let deleted_at, deleted_by: String?
                let created_at, updated_at: String?
                let last_modified_by: String?
            }
            let rows: [Row] = try await client.select(
                Row.self,
                from: SupabaseTable.contracts,
                filters: [
                    .eq("company_id", companyID.uuidString),
                    .eq("is_deleted", false)
                ],
                orderBy: "updated_at",
                ascending: false
            )

            let isoFmt  = ISO8601DateFormatter()
            isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "yyyy-MM-dd"
            func parseTS(_ s: String?) -> Date? {
                guard let s = s else { return nil }
                return isoFmt.date(from: s) ?? dateFmt.date(from: s)
            }

            // Preserve local edits: keep pending/local/failed, overwrite synced.
            var merged = store.contracts.filter {
                $0.syncStatus == .pending || $0.syncStatus == .local || $0.syncStatus == .failed
            }
            for row in rows {
                guard let uuid    = UUID(uuidString: row.id),
                      let coUUID  = UUID(uuidString: row.company_id),
                      let cType   = ContractType(rawValue: row.contract_type)
                else { continue }
                var c = Contract(
                    title:           row.title,
                    contractType:    cType,
                    counterpartyName: row.counterparty_name
                )
                c.id                    = uuid
                c.companyID             = coUUID
                c.externalID            = row.external_id
                c.contractNumber        = row.contract_number
                c.status                = ContractStatus(rawValue: row.status) ?? .draft
                c.counterpartyType      = row.counterparty_type.flatMap(CounterpartyType.init(rawValue:))
                c.counterpartyID        = row.counterparty_id.flatMap(UUID.init(uuidString:))
                c.counterpartyEmail     = row.counterparty_email
                c.projectID             = row.project_id.flatMap(UUID.init(uuidString:))
                c.opportunityID         = row.opportunity_id.flatMap(UUID.init(uuidString:))
                c.parentContractID      = row.parent_contract_id.flatMap(UUID.init(uuidString:))
                c.quoteID               = row.quote_id.flatMap(UUID.init(uuidString:))
                c.supersedesContractID  = row.supersedes_contract_id.flatMap(UUID.init(uuidString:))
                c.contractValue         = row.contract_value.map { Decimal($0) }
                c.currency              = row.currency
                c.retainagePercent      = row.retainage_percent.map { Decimal($0) }
                c.effectiveDate         = parseTS(row.effective_date)
                c.expiryDate            = parseTS(row.expiry_date)
                c.renewalDate           = parseTS(row.renewal_date)
                c.executedDate          = parseTS(row.executed_date)
                c.terminationDate       = parseTS(row.termination_date)
                c.version               = row.version
                c.paymentTerms          = row.payment_terms
                c.warrantyPeriodDays    = row.warranty_period_days
                c.insuranceRequired     = row.insurance_required
                c.bondRequired          = row.bond_required
                c.governingLaw          = row.governing_law
                c.disputeResolution     = row.dispute_resolution
                c.riskScore             = row.risk_score.flatMap(RiskLevel.init(rawValue:))
                c.riskSummary           = row.risk_summary
                c.aiReviewStatus        = row.ai_review_status.flatMap(ContractAIReviewStatus.init(rawValue:)) ?? .notReviewed
                c.aiReviewedAt          = parseTS(row.ai_reviewed_at)
                c.primaryDocumentURL    = row.primary_document_url
                c.primaryDocumentName   = row.primary_document_name
                c.notes                 = row.notes
                c.assignedReviewerID    = row.assigned_reviewer_id.flatMap(UUID.init(uuidString:))
                c.approvedByID          = row.approved_by_id.flatMap(UUID.init(uuidString:))
                c.reviewedAt            = parseTS(row.reviewed_at)
                c.approvedAt            = parseTS(row.approved_at)
                c.isDeleted             = row.is_deleted
                c.deletedAt             = parseTS(row.deleted_at)
                c.deletedBy             = row.deleted_by
                c.createdAt             = parseTS(row.created_at) ?? Date()
                c.updatedAt             = parseTS(row.updated_at) ?? Date()
                c.lastModifiedBy        = row.last_modified_by ?? ""
                c.lastModifiedAt        = c.updatedAt
                c.syncStatus            = .synced

                merged.removeAll { $0.id == uuid }
                merged.append(c)
            }
            store.contracts = merged
            store.objectWillChange.send()
        } catch {
            // Table may not exist yet on a fresh install; ignore so the
            // rest of the pull pipeline continues. Real errors surface
            // through the per-call audit log.
        }
    }

    func pushPendingContracts() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.contracts.filter { $0.syncStatus == .pending }
        guard !pending.isEmpty else { return }

        let isoFmt  = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"

        for c in pending {
            do {
                struct Row: Encodable {
                    let id, company_id, title, contract_type, status, counterparty_name: String
                    let external_id, contract_number: String?
                    let counterparty_type: String?
                    let counterparty_id, counterparty_email: String?
                    /// FIX (debug audit): persist CRM linkage.
                    /// contracts.opportunity_id is NOT NULL on prod;
                    /// pre-fix the Row struct omitted the field, so
                    /// every contract push silently failed.
                    let opportunity_id: String?
                    let project_id, parent_contract_id, quote_id, supersedes_contract_id: String?
                    let contract_value: Double?
                    let currency: String
                    let retainage_percent: Double?
                    let effective_date, expiry_date, renewal_date, executed_date, termination_date: String?
                    let version: Int
                    let payment_terms: String?
                    let warranty_period_days: Int?
                    let insurance_required, bond_required: Bool
                    let governing_law, dispute_resolution: String?
                    let risk_score, risk_summary, ai_review_status: String?
                    let ai_reviewed_at: String?
                    let primary_document_url, primary_document_name: String?
                    let notes: String?
                    let assigned_reviewer_id, approved_by_id: String?
                    let reviewed_at, approved_at: String?
                    let last_modified_by: String?
                    let is_deleted: Bool
                    let deleted_at, deleted_by: String?
                    let created_at, updated_at: String
                }
                let row = Row(
                    id:                     c.id.uuidString,
                    company_id:             companyID.uuidString,
                    title:                  c.title,
                    contract_type:          c.contractType.rawValue,
                    status:                 c.status.rawValue,
                    counterparty_name:      c.counterpartyName,
                    external_id:            c.externalID,
                    contract_number:        c.contractNumber,
                    counterparty_type:      c.counterpartyType?.rawValue,
                    counterparty_id:        c.counterpartyID?.uuidString,
                    counterparty_email:     c.counterpartyEmail,
                    opportunity_id:         c.opportunityID?.uuidString,
                    project_id:             c.projectID?.uuidString,
                    parent_contract_id:     c.parentContractID?.uuidString,
                    quote_id:               c.quoteID?.uuidString,
                    supersedes_contract_id: c.supersedesContractID?.uuidString,
                    contract_value:         c.contractValue.map { NSDecimalNumber(decimal: $0).doubleValue },
                    currency:               c.currency,
                    retainage_percent:      c.retainagePercent.map { NSDecimalNumber(decimal: $0).doubleValue },
                    effective_date:         c.effectiveDate.map    { dateFmt.string(from: $0) },
                    expiry_date:            c.expiryDate.map       { dateFmt.string(from: $0) },
                    renewal_date:           c.renewalDate.map      { dateFmt.string(from: $0) },
                    executed_date:          c.executedDate.map     { dateFmt.string(from: $0) },
                    termination_date:       c.terminationDate.map  { dateFmt.string(from: $0) },
                    version:                c.version,
                    payment_terms:          c.paymentTerms,
                    warranty_period_days:   c.warrantyPeriodDays,
                    insurance_required:     c.insuranceRequired,
                    bond_required:          c.bondRequired,
                    governing_law:          c.governingLaw,
                    dispute_resolution:     c.disputeResolution,
                    risk_score:             c.riskScore?.rawValue,
                    risk_summary:           c.riskSummary,
                    ai_review_status:       c.aiReviewStatus.rawValue,
                    ai_reviewed_at:         c.aiReviewedAt.map     { isoFmt.string(from: $0) },
                    primary_document_url:   c.primaryDocumentURL,
                    primary_document_name:  c.primaryDocumentName,
                    notes:                  c.notes,
                    assigned_reviewer_id:   c.assignedReviewerID?.uuidString,
                    approved_by_id:         c.approvedByID?.uuidString,
                    reviewed_at:            c.reviewedAt.map       { isoFmt.string(from: $0) },
                    approved_at:            c.approvedAt.map       { isoFmt.string(from: $0) },
                    last_modified_by:       c.lastModifiedBy.isEmpty ? nil : c.lastModifiedBy,
                    is_deleted:             c.isDeleted,
                    deleted_at:             c.deletedAt.map        { isoFmt.string(from: $0) },
                    deleted_by:             c.deletedBy,
                    created_at:             isoFmt.string(from: c.createdAt),
                    updated_at:             isoFmt.string(from: c.updatedAt)
                )
                try await client.upsert(row, into: SupabaseTable.contracts)
                if let i = store.contracts.firstIndex(where: { $0.id == c.id }) {
                    store.contracts[i].syncStatus = .synced
                }
                store.contracts.removeAll { $0.isDeleted && $0.syncStatus == .synced }
                await MainActor.run { store.clearSyncError(id: c.id) }
            } catch {
                if let i = store.contracts.firstIndex(where: { $0.id == c.id }) {
                    store.contracts[i].syncStatus = .failed
                }
                await MainActor.run { store.recordSyncError(id: c.id, error: error) }
                CrashReporter.capture(error: error, context: [
                    "operation":       "pushPendingContracts",
                    "contract_id":      c.id.uuidString,
                    "contract_number":  c.contractNumber ?? ""
                ])
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Contract Clauses
    // ─────────────────────────────────────────────────────────────────

    func pullContractClauses() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, contract_id, clause_kind: String
                let company_id: String
                let title, original_text, plain_english, risk_level, risk_explanation: String?
                let page_reference: Int?
                let display_order: Int
                let source: String
                let is_deleted: Bool
                let created_at: String?
            }
            let rows: [Row] = try await client.select(
                Row.self,
                from: SupabaseTable.contractClauses,
                filters: [
                    .eq("company_id", companyID.uuidString),
                    .eq("is_deleted", false)
                ]
            )

            let isoFmt = ISO8601DateFormatter()
            isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            var merged = store.contractClauses.filter {
                $0.syncStatus == .pending || $0.syncStatus == .local || $0.syncStatus == .failed
            }
            for row in rows {
                guard let uuid    = UUID(uuidString: row.id),
                      let cID     = UUID(uuidString: row.contract_id),
                      let coUUID  = UUID(uuidString: row.company_id),
                      let kind    = ClauseKind(rawValue: row.clause_kind)
                else { continue }
                var clause = ContractClause(contractID: cID, clauseKind: kind)
                clause.id              = uuid
                clause.companyID       = coUUID
                clause.title           = row.title
                clause.originalText    = row.original_text
                clause.plainEnglish    = row.plain_english
                clause.riskLevel       = row.risk_level.flatMap(RiskLevel.init(rawValue:))
                clause.riskExplanation = row.risk_explanation
                clause.pageReference   = row.page_reference
                clause.displayOrder    = row.display_order
                clause.source          = row.source
                clause.isDeleted       = row.is_deleted
                clause.createdAt       = row.created_at.flatMap { isoFmt.date(from: $0) } ?? Date()
                clause.syncStatus      = .synced
                merged.removeAll { $0.id == uuid }
                merged.append(clause)
            }
            store.contractClauses = merged
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    func pushPendingContractClauses() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.contractClauses.filter { $0.syncStatus == .pending }
        guard !pending.isEmpty else { return }

        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for clause in pending {
            do {
                struct Row: Encodable {
                    let id, company_id, contract_id, clause_kind: String
                    let title, original_text, plain_english, risk_level, risk_explanation: String?
                    let page_reference: Int?
                    let display_order: Int
                    let source: String
                    let is_deleted: Bool
                    let created_at: String
                }
                let row = Row(
                    id:               clause.id.uuidString,
                    company_id:       companyID.uuidString,
                    contract_id:      clause.contractID.uuidString,
                    clause_kind:      clause.clauseKind.rawValue,
                    title:            clause.title,
                    original_text:    clause.originalText,
                    plain_english:    clause.plainEnglish,
                    risk_level:       clause.riskLevel?.rawValue,
                    risk_explanation: clause.riskExplanation,
                    page_reference:   clause.pageReference,
                    display_order:    clause.displayOrder,
                    source:           clause.source,
                    is_deleted:       clause.isDeleted,
                    created_at:       isoFmt.string(from: clause.createdAt)
                )
                try await client.upsert(row, into: SupabaseTable.contractClauses)
                if let i = store.contractClauses.firstIndex(where: { $0.id == clause.id }) {
                    store.contractClauses[i].syncStatus = .synced
                }
            } catch {
                if let i = store.contractClauses.firstIndex(where: { $0.id == clause.id }) {
                    store.contractClauses[i].syncStatus = .failed
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Contract Milestones
    // ─────────────────────────────────────────────────────────────────

    func pullContractMilestones() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, contract_id, title, milestone_type, status: String
                let company_id: String
                let description: String?
                let milestone_date: String
                let amount_due: Double?
                let completed_at: String?
                let completed_by_id: String?
                let notes: String?
                let is_deleted: Bool
                let created_at, updated_at: String?
            }
            let rows: [Row] = try await client.select(
                Row.self,
                from: SupabaseTable.contractMilestones,
                filters: [
                    .eq("company_id", companyID.uuidString),
                    .eq("is_deleted", false)
                ]
            )

            let isoFmt  = ISO8601DateFormatter()
            isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "yyyy-MM-dd"

            var merged = store.contractMilestones.filter {
                $0.syncStatus == .pending || $0.syncStatus == .local || $0.syncStatus == .failed
            }
            for row in rows {
                guard let uuid   = UUID(uuidString: row.id),
                      let cID    = UUID(uuidString: row.contract_id),
                      let coUUID = UUID(uuidString: row.company_id),
                      let mDate  = dateFmt.date(from: row.milestone_date),
                      let mType  = MilestoneType(rawValue: row.milestone_type)
                else { continue }
                var m = ContractMilestone(
                    contractID: cID,
                    title: row.title,
                    milestoneDate: mDate,
                    milestoneType: mType
                )
                m.id            = uuid
                m.companyID     = coUUID
                m.description   = row.description
                m.amountDue     = row.amount_due.map { Decimal($0) }
                m.status        = MilestoneStatus(rawValue: row.status) ?? .upcoming
                m.completedAt   = row.completed_at.flatMap { isoFmt.date(from: $0) }
                m.completedByID = row.completed_by_id.flatMap(UUID.init(uuidString:))
                m.notes         = row.notes
                m.isDeleted     = row.is_deleted
                m.createdAt     = row.created_at.flatMap { isoFmt.date(from: $0) } ?? Date()
                m.updatedAt     = row.updated_at.flatMap { isoFmt.date(from: $0) } ?? Date()
                m.syncStatus    = .synced
                merged.removeAll { $0.id == uuid }
                merged.append(m)
            }
            store.contractMilestones = merged
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Compliance Documents (Phase 2A)
    // ─────────────────────────────────────────────────────────────────

    func pullComplianceDocuments() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, company_id, kind, document_type, title: String
                let contract_id, carrier, policy_number, named_insured: String?
                let coverage_limit, aggregate_limit, deductible: Double?
                let currency: String
                let effective_date: String?
                let expiry_date: String?            // nullable for requirement-only rows
                let is_requirement_only: Bool?
                let document_url, document_filename, notes: String?
                let uploaded_by: String?
                let is_deleted: Bool
                let created_at, updated_at: String?
            }
            let rows: [Row] = try await client.select(
                Row.self,
                from: SupabaseTable.complianceDocuments,
                filters: [
                    .eq("company_id", companyID.uuidString),
                    .eq("is_deleted", false)
                ],
                orderBy: "expiry_date",
                ascending: true
            )

            let isoFmt  = ISO8601DateFormatter()
            isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "yyyy-MM-dd"
            func parseTS(_ s: String?) -> Date? {
                guard let s = s else { return nil }
                return isoFmt.date(from: s) ?? dateFmt.date(from: s)
            }

            // Preserve in-flight edits.
            var merged = store.complianceDocuments.filter {
                $0.syncStatus == .pending || $0.syncStatus == .local || $0.syncStatus == .failed
            }
            for row in rows {
                guard let uuid    = UUID(uuidString: row.id),
                      let coUUID  = UUID(uuidString: row.company_id),
                      let kind    = ComplianceKind(rawValue: row.kind),
                      let dtype   = ComplianceDocumentType(rawValue: row.document_type)
                else { continue }
                // Expiry is nullable for requirement-only rows.
                let expiry = row.expiry_date.flatMap { dateFmt.date(from: $0) }
                var d = ComplianceDocument(
                    kind:         kind,
                    documentType: dtype,
                    title:        row.title
                )
                d.id              = uuid
                d.companyID       = coUUID
                d.contractID      = row.contract_id.flatMap(UUID.init(uuidString:))
                d.carrier         = row.carrier
                d.policyNumber    = row.policy_number
                d.namedInsured    = row.named_insured
                d.coverageLimit   = row.coverage_limit.map { Decimal($0) }
                d.aggregateLimit  = row.aggregate_limit.map { Decimal($0) }
                d.deductible      = row.deductible.map { Decimal($0) }
                d.currency        = row.currency
                d.effectiveDate   = parseTS(row.effective_date)
                d.expiryDate      = expiry
                d.isRequirementOnly = row.is_requirement_only ?? false
                d.documentURL     = row.document_url
                d.documentFilename = row.document_filename
                d.notes           = row.notes
                d.uploadedBy      = row.uploaded_by.flatMap(UUID.init(uuidString:))
                d.isDeleted       = row.is_deleted
                d.createdAt       = parseTS(row.created_at) ?? Date()
                d.updatedAt       = parseTS(row.updated_at) ?? Date()
                d.syncStatus      = .synced
                merged.removeAll { $0.id == uuid }
                merged.append(d)
            }
            store.complianceDocuments = merged
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    func pushPendingComplianceDocuments() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.complianceDocuments.filter { $0.syncStatus == .pending }
        guard !pending.isEmpty else { return }

        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"

        struct Row: Encodable {
            let id, company_id, kind, document_type, title: String
            let contract_id, carrier, policy_number, named_insured: String?
            let coverage_limit, aggregate_limit, deductible: Double?
            let currency: String
            let effective_date: String?
            let expiry_date: String?
            let is_requirement_only: Bool
            let document_url, document_filename, notes: String?
            let uploaded_by: String?
            let is_deleted: Bool
            let created_at, updated_at: String
        }

        for d in pending {
            do {
                let row = Row(
                    id:                  d.id.uuidString,
                    company_id:          companyID.uuidString,
                    kind:                d.kind.rawValue,
                    document_type:       d.documentType.rawValue,
                    title:               d.title,
                    contract_id:         d.contractID?.uuidString,
                    carrier:             d.carrier,
                    policy_number:       d.policyNumber,
                    named_insured:       d.namedInsured,
                    coverage_limit:      d.coverageLimit.map  { NSDecimalNumber(decimal: $0).doubleValue },
                    aggregate_limit:     d.aggregateLimit.map { NSDecimalNumber(decimal: $0).doubleValue },
                    deductible:          d.deductible.map     { NSDecimalNumber(decimal: $0).doubleValue },
                    currency:            d.currency,
                    effective_date:      d.effectiveDate.map  { dateFmt.string(from: $0) },
                    expiry_date:         d.expiryDate.map     { dateFmt.string(from: $0) },
                    is_requirement_only: d.isRequirementOnly,
                    document_url:        d.documentURL,
                    document_filename:   d.documentFilename,
                    notes:               d.notes,
                    uploaded_by:         d.uploadedBy?.uuidString,
                    is_deleted:          d.isDeleted,
                    created_at:          isoFmt.string(from: d.createdAt),
                    updated_at:          isoFmt.string(from: d.updatedAt)
                )
                try await client.upsert(row, into: SupabaseTable.complianceDocuments)
                if let i = store.complianceDocuments.firstIndex(where: { $0.id == d.id }) {
                    store.complianceDocuments[i].syncStatus = .synced
                }
            } catch {
                if let i = store.complianceDocuments.firstIndex(where: { $0.id == d.id }) {
                    store.complianceDocuments[i].syncStatus = .failed
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Lien Waivers (Phase 2B)
    // ─────────────────────────────────────────────────────────────────

    func pullLienWaivers() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, company_id, waiver_type, status, waiver_from_name: String
                let contract_id, invoice_id, payment_reference: String?
                let waiver_from_id, waiver_from_email, waiver_to_name: String?
                let through_date: String?
                let amount, retainage_excluded: Double?
                let currency: String
                let requested_at: String
                let sent_at, signed_at, received_at: String?
                let signature_data_url, signed_by_name, signed_by_email: String?
                let signed_by_ip, signed_user_agent: String?
                let document_url, document_filename: String?
                let magic_link_token: String?
                let magic_link_expires_at, magic_link_sent_at, magic_link_revoked_at: String?
                let notes: String?
                let created_by: String?
                let created_at, updated_at: String?
                let is_deleted: Bool
            }
            let rows: [Row] = try await client.select(
                Row.self,
                from: SupabaseTable.lienWaivers,
                filters: [
                    .eq("company_id", companyID.uuidString),
                    .eq("is_deleted", false)
                ],
                orderBy: "requested_at",
                ascending: false
            )

            let isoFmt = ISO8601DateFormatter()
            isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "yyyy-MM-dd"
            func parseTS(_ s: String?) -> Date? {
                guard let s = s else { return nil }
                return isoFmt.date(from: s) ?? dateFmt.date(from: s)
            }

            var merged = store.lienWaivers.filter {
                $0.syncStatus == .pending || $0.syncStatus == .local || $0.syncStatus == .failed
            }
            for row in rows {
                guard let uuid    = UUID(uuidString: row.id),
                      let coUUID  = UUID(uuidString: row.company_id),
                      let kind    = LienWaiverType(rawValue: row.waiver_type)
                else { continue }
                var w = LienWaiver(
                    waiverType:     kind,
                    waiverFromName: row.waiver_from_name
                )
                w.id                   = uuid
                w.companyID            = coUUID
                w.contractID           = row.contract_id.flatMap(UUID.init(uuidString:))
                w.invoiceID            = row.invoice_id.flatMap(UUID.init(uuidString:))
                w.paymentReference     = row.payment_reference
                w.waiverFromID         = row.waiver_from_id.flatMap(UUID.init(uuidString:))
                w.waiverFromEmail      = row.waiver_from_email
                w.waiverToName         = row.waiver_to_name
                w.throughDate          = parseTS(row.through_date)
                w.amount               = row.amount.map { Decimal($0) }
                w.retainageExcluded    = row.retainage_excluded.map { Decimal($0) }
                w.currency             = row.currency
                w.status               = LienWaiverStatus(rawValue: row.status) ?? .requested
                w.requestedAt          = parseTS(row.requested_at) ?? Date()
                w.sentAt               = parseTS(row.sent_at)
                w.signedAt             = parseTS(row.signed_at)
                w.receivedAt           = parseTS(row.received_at)
                w.signatureDataURL     = row.signature_data_url
                w.signedByName         = row.signed_by_name
                w.signedByEmail        = row.signed_by_email
                w.signedByIP           = row.signed_by_ip
                w.signedUserAgent      = row.signed_user_agent
                w.documentURL          = row.document_url
                w.documentFilename     = row.document_filename
                w.magicLinkToken       = row.magic_link_token
                w.magicLinkExpiresAt   = parseTS(row.magic_link_expires_at)
                w.magicLinkSentAt      = parseTS(row.magic_link_sent_at)
                w.magicLinkRevokedAt   = parseTS(row.magic_link_revoked_at)
                w.notes                = row.notes
                w.createdBy            = row.created_by.flatMap(UUID.init(uuidString:))
                w.createdAt            = parseTS(row.created_at) ?? Date()
                w.updatedAt            = parseTS(row.updated_at) ?? Date()
                w.isDeleted            = row.is_deleted
                w.syncStatus           = .synced
                merged.removeAll { $0.id == uuid }
                merged.append(w)
            }
            store.lienWaivers = merged
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    func pushPendingLienWaivers() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.lienWaivers.filter { $0.syncStatus == .pending }
        guard !pending.isEmpty else { return }

        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"

        struct Row: Encodable {
            let id, company_id, waiver_type, status, waiver_from_name: String
            let contract_id, invoice_id, payment_reference: String?
            let waiver_from_id, waiver_from_email, waiver_to_name: String?
            let through_date: String?
            let amount, retainage_excluded: Double?
            let currency: String
            let requested_at: String
            let sent_at, signed_at, received_at: String?
            let signature_data_url, signed_by_name, signed_by_email: String?
            let signed_by_ip, signed_user_agent: String?
            let document_url, document_filename: String?
            let notes: String?
            let created_by: String?
            let created_at, updated_at: String
            let is_deleted: Bool
        }

        for w in pending {
            do {
                let row = Row(
                    id:                  w.id.uuidString,
                    company_id:          companyID.uuidString,
                    waiver_type:         w.waiverType.rawValue,
                    status:              w.status.rawValue,
                    waiver_from_name:    w.waiverFromName,
                    contract_id:         w.contractID?.uuidString,
                    invoice_id:          w.invoiceID?.uuidString,
                    payment_reference:   w.paymentReference,
                    waiver_from_id:      w.waiverFromID?.uuidString,
                    waiver_from_email:   w.waiverFromEmail,
                    waiver_to_name:      w.waiverToName,
                    through_date:        w.throughDate.map { dateFmt.string(from: $0) },
                    amount:              w.amount.map { NSDecimalNumber(decimal: $0).doubleValue },
                    retainage_excluded:  w.retainageExcluded.map { NSDecimalNumber(decimal: $0).doubleValue },
                    currency:            w.currency,
                    requested_at:        isoFmt.string(from: w.requestedAt),
                    sent_at:             w.sentAt.map     { isoFmt.string(from: $0) },
                    signed_at:           w.signedAt.map   { isoFmt.string(from: $0) },
                    received_at:         w.receivedAt.map { isoFmt.string(from: $0) },
                    signature_data_url:  w.signatureDataURL,
                    signed_by_name:      w.signedByName,
                    signed_by_email:     w.signedByEmail,
                    signed_by_ip:        w.signedByIP,
                    signed_user_agent:   w.signedUserAgent,
                    document_url:        w.documentURL,
                    document_filename:   w.documentFilename,
                    notes:               w.notes,
                    created_by:          w.createdBy?.uuidString,
                    created_at:          isoFmt.string(from: w.createdAt),
                    updated_at:          isoFmt.string(from: w.updatedAt),
                    is_deleted:          w.isDeleted
                )
                try await client.upsert(row, into: SupabaseTable.lienWaivers)
                if let i = store.lienWaivers.firstIndex(where: { $0.id == w.id }) {
                    store.lienWaivers[i].syncStatus = .synced
                }
            } catch {
                if let i = store.lienWaivers.firstIndex(where: { $0.id == w.id }) {
                    store.lienWaivers[i].syncStatus = .failed
                }
            }
        }
    }

    func pushPendingContractMilestones() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.contractMilestones.filter { $0.syncStatus == .pending }
        guard !pending.isEmpty else { return }

        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"

        for m in pending {
            do {
                struct Row: Encodable {
                    let id, company_id, contract_id, title, milestone_type, status: String
                    let description: String?
                    let milestone_date: String
                    let amount_due: Double?
                    let completed_at: String?
                    let completed_by_id: String?
                    let notes: String?
                    let is_deleted: Bool
                    let created_at, updated_at: String
                }
                let row = Row(
                    id:               m.id.uuidString,
                    company_id:       companyID.uuidString,
                    contract_id:      m.contractID.uuidString,
                    title:            m.title,
                    milestone_type:   m.milestoneType.rawValue,
                    status:           m.status.rawValue,
                    description:      m.description,
                    milestone_date:   dateFmt.string(from: m.milestoneDate),
                    amount_due:       m.amountDue.map { NSDecimalNumber(decimal: $0).doubleValue },
                    completed_at:     m.completedAt.map { isoFmt.string(from: $0) },
                    completed_by_id:  m.completedByID?.uuidString,
                    notes:            m.notes,
                    is_deleted:       m.isDeleted,
                    created_at:       isoFmt.string(from: m.createdAt),
                    updated_at:       isoFmt.string(from: m.updatedAt)
                )
                try await client.upsert(row, into: SupabaseTable.contractMilestones)
                if let i = store.contractMilestones.firstIndex(where: { $0.id == m.id }) {
                    store.contractMilestones[i].syncStatus = .synced
                }
            } catch {
                if let i = store.contractMilestones.firstIndex(where: { $0.id == m.id }) {
                    store.contractMilestones[i].syncStatus = .failed
                }
            }
        }
    }
}
