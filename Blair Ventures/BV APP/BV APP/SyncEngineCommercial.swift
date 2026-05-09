// SyncEngineCommercial.swift
// Aski IQ – Supabase Sync for Commercial Modules
// Covers: Change Orders, RFIs, Project Budgets, Subcontractors,
//         Sub-Contracts, Invoices, Purchase Orders, Material Requests, Suppliers

import Foundation
import Combine
import Supabase

// MARK: - Module-level Helpers

private let isoFull: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let isoDateFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

private func jsonString<T: Encodable>(_ value: T) -> String {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    return (try? enc.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
}

private func decodeJSON<T: Decodable>(_ string: String?, as type: T.Type) -> T? {
    guard let s = string, let data = s.data(using: .utf8) else { return nil }
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    return try? dec.decode(T.self, from: data)
}

private func toDouble(_ decimal: Decimal) -> Double {
    NSDecimalNumber(decimal: decimal).doubleValue
}

/// Converts a Double from Supabase to Decimal without floating-point rounding error.
/// Uses string round-trip which preserves the decimal representation exactly.
private func fromDouble(_ value: Double) -> Decimal {
    Decimal(string: String(value)) ?? 0
}

/// Optional variant — returns 0 when nil.
private func fromDouble(_ value: Double?) -> Decimal {
    guard let v = value else { return 0 }
    return Decimal(string: String(v)) ?? 0
}

private func parseDate(_ str: String?) -> Date? {
    guard let s = str else { return nil }
    return isoFull.date(from: s) ?? isoDateFmt.date(from: s)
}

// MARK: - SyncEngine Commercial Extension

extension SyncEngine {

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Change Orders
    // ─────────────────────────────────────────────────────────────────────────

    func pullChangeOrders(role: UserRole) async {
        guard !role.isFieldRole && !role.isExternal else { return }
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, number, title, project_id, type, status: String
                let description: String?
                let reason, notes: String?
                let cost_impact: Double
                let schedule_impact_days: Int
                let line_items_json: String?
                let submitted_date, approved_date, rejected_date: String?
                let approved_by_name, client_reference_number: String?
                let company_id: String?
                // Sample-data tracking
                let is_sample_data: Bool?
                let sample_data_batch_id: String?
                let sample_data_seed_version: String?
                let sample_data_created_at: String?
                let sample_data_created_by: String?
            }
            let rows: [Row] = try await supabase
                .from(SupabaseTable.changeOrders)
                .select()
                .eq("company_id", value: companyID.uuidString)
                .eq("is_deleted", value: false)
                .execute().value

            var merged = store.changeOrders.filter {
                $0.syncStatus == .pending || $0.syncStatus == .local
            }
            for row in rows {
                guard let uuid   = UUID(uuidString: row.id),
                      let projID = UUID(uuidString: row.project_id) else { continue }
                var co = ChangeOrder(number: row.number, title: row.title, projectID: projID)
                co.id                    = uuid
                co.companyID             = row.company_id.flatMap(UUID.init(uuidString:))
                co.type                  = ChangeOrderType(rawValue: row.type)     ?? .other
                co.status                = ChangeOrderStatus(rawValue: row.status) ?? .draft
                co.description           = row.description ?? ""
                co.reason                = row.reason
                co.notes                 = row.notes
                co.costImpact            = fromDouble(row.cost_impact)
                co.scheduleImpactDays    = row.schedule_impact_days
                co.lineItems             = decodeJSON(row.line_items_json, as: [ChangeOrderLineItem].self) ?? []
                co.submittedDate         = parseDate(row.submitted_date)
                co.approvedDate          = parseDate(row.approved_date)
                co.rejectedDate          = parseDate(row.rejected_date)
                co.approvedByName        = row.approved_by_name
                co.clientReferenceNumber = row.client_reference_number
                co.syncStatus            = .synced
                co.isSampleData          = row.is_sample_data ?? false
                co.sampleDataBatchID     = row.sample_data_batch_id.flatMap(UUID.init(uuidString:))
                co.sampleDataSeedVersion = row.sample_data_seed_version
                co.sampleDataCreatedAt   = parseDate(row.sample_data_created_at)
                co.sampleDataCreatedBy   = row.sample_data_created_by.flatMap(UUID.init(uuidString:))
                merged.removeAll { $0.id == uuid }
                merged.append(co)
            }
            store.changeOrders = merged
            store.saveChangeOrders()
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    func pushPendingChangeOrders() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.changeOrders.filter { $0.syncStatus == .pending }
        guard !pending.isEmpty else { return }
        for co in pending {
            do {
                struct Row: Codable {
                    let id, company_id, number, title, project_id, type, status: String
                    let description, reason, notes: String?
                    let cost_impact: Double
                    let schedule_impact_days: Int
                    let line_items_json: String?
                    let submitted_date, approved_date, rejected_date: String?
                    let approved_by_name, client_reference_number: String?
                    let last_modified_by: String?
                    let is_deleted: Bool
                    let deleted_at: String?
                    let deleted_by: String?
                    // Sample-data tracking
                    let is_sample_data: Bool
                    let sample_data_batch_id: String?
                    let sample_data_seed_version: String?
                    let sample_data_created_at: String?
                    let sample_data_created_by: String?
                }
                let row = Row(
                    id:                      co.id.uuidString,
                    company_id:              companyID.uuidString,
                    number:                  co.number,
                    title:                   co.title,
                    project_id:              co.projectID.uuidString,
                    type:                    co.type.rawValue,
                    status:                  co.status.rawValue,
                    description:             co.description.isEmpty ? nil : co.description,
                    reason:                  co.reason,
                    notes:                   co.notes,
                    cost_impact:             toDouble(co.effectiveCostImpact),
                    schedule_impact_days:    co.scheduleImpactDays,
                    line_items_json:         jsonString(co.lineItems),
                    submitted_date:          co.submittedDate.map { isoFull.string(from: $0) },
                    approved_date:           co.approvedDate.map  { isoFull.string(from: $0) },
                    rejected_date:           co.rejectedDate.map  { isoFull.string(from: $0) },
                    approved_by_name:        co.approvedByName,
                    client_reference_number: co.clientReferenceNumber,
                    last_modified_by:        co.lastModifiedBy.isEmpty ? nil : co.lastModifiedBy,
                    is_deleted:              co.isDeleted,
                    deleted_at:              co.deletedAt.map { isoFull.string(from: $0) },
                    deleted_by:              co.deletedBy,
                    is_sample_data:           co.isSampleData,
                    sample_data_batch_id:     co.sampleDataBatchID?.uuidString,
                    sample_data_seed_version: co.sampleDataSeedVersion,
                    sample_data_created_at:   co.sampleDataCreatedAt.map { isoFull.string(from: $0) },
                    sample_data_created_by:   co.sampleDataCreatedBy?.uuidString
                )
                try await supabase.from(SupabaseTable.changeOrders).upsert(row).execute()
                if let i = store.changeOrders.firstIndex(where: { $0.id == co.id }) {
                    store.changeOrders[i].syncStatus = .synced
                }
                store.changeOrders.removeAll { $0.isDeleted && $0.syncStatus == .synced }
            } catch {
                if let i = store.changeOrders.firstIndex(where: { $0.id == co.id }) {
                    store.changeOrders[i].syncStatus = .failed
                }
            }
        }
        store.saveChangeOrders()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: RFIs
    // ─────────────────────────────────────────────────────────────────────────

    func pullRFIs(role: UserRole) async {
        guard !role.isExternal else { return }
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, number, title, project_id, status, priority, category: String
                let question: String?
                let reference, submitted_by_name: String?
                let answer, answered_by_name, internal_notes: String?
                let has_cost_impact, has_schedule_impact: Bool
                let required_by_date, submitted_date, answered_date: String?
            }
            let rows: [Row] = try await supabase
                .from(SupabaseTable.rfis)
                .select()
                .eq("company_id", value: companyID.uuidString)
                .eq("is_deleted", value: false)
                .execute().value

            var merged = store.rfis.filter {
                $0.syncStatus == .pending || $0.syncStatus == .local
            }
            for row in rows {
                guard let uuid   = UUID(uuidString: row.id),
                      let projID = UUID(uuidString: row.project_id) else { continue }
                var rfi = RFI(number: row.number, title: row.title, projectID: projID)
                rfi.id                = uuid
                rfi.status            = RFIStatus(rawValue: row.status)     ?? .draft
                rfi.priority          = RFIPriority(rawValue: row.priority) ?? .normal
                rfi.category          = RFICategory(rawValue: row.category) ?? .other
                rfi.question          = row.question ?? ""
                rfi.reference         = row.reference
                rfi.submittedByName   = row.submitted_by_name
                rfi.answer            = row.answer
                rfi.answeredByName    = row.answered_by_name
                rfi.internalNotes     = row.internal_notes
                rfi.hasCostImpact     = row.has_cost_impact
                rfi.hasScheduleImpact = row.has_schedule_impact
                rfi.requiredByDate    = parseDate(row.required_by_date)
                rfi.submittedDate     = parseDate(row.submitted_date)
                rfi.answeredDate      = parseDate(row.answered_date)
                rfi.syncStatus        = .synced
                merged.removeAll { $0.id == uuid }
                merged.append(rfi)
            }
            store.rfis = merged
            store.saveRFIs()
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    func pushPendingRFIs() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.rfis.filter { $0.syncStatus == .pending }
        guard !pending.isEmpty else { return }
        for rfi in pending {
            do {
                struct Row: Codable {
                    let id, company_id, number, title, project_id, status, priority, category: String
                    let question: String?
                    let reference, submitted_by_name: String?
                    let answer, answered_by_name, internal_notes: String?
                    let has_cost_impact, has_schedule_impact: Bool
                    let required_by_date, submitted_date, answered_date: String?
                    let last_modified_by: String?
                    let is_deleted: Bool
                    let deleted_at: String?
                    let deleted_by: String?
                }
                let row = Row(
                    id:                  rfi.id.uuidString,
                    company_id:          companyID.uuidString,
                    number:              rfi.number,
                    title:               rfi.title,
                    project_id:          rfi.projectID.uuidString,
                    status:              rfi.status.rawValue,
                    priority:            rfi.priority.rawValue,
                    category:            rfi.category.rawValue,
                    question:            rfi.question.isEmpty ? nil : rfi.question,
                    reference:           rfi.reference,
                    submitted_by_name:   rfi.submittedByName,
                    answer:              rfi.answer,
                    answered_by_name:    rfi.answeredByName,
                    internal_notes:      rfi.internalNotes,
                    has_cost_impact:     rfi.hasCostImpact,
                    has_schedule_impact: rfi.hasScheduleImpact,
                    required_by_date:    rfi.requiredByDate.map { isoFull.string(from: $0) },
                    submitted_date:      rfi.submittedDate.map  { isoFull.string(from: $0) },
                    answered_date:       rfi.answeredDate.map   { isoFull.string(from: $0) },
                    last_modified_by:    rfi.lastModifiedBy.isEmpty ? nil : rfi.lastModifiedBy,
                    is_deleted:          rfi.isDeleted,
                    deleted_at:          rfi.deletedAt.map { isoFull.string(from: $0) },
                    deleted_by:          rfi.deletedBy
                )
                try await supabase.from(SupabaseTable.rfis).upsert(row).execute()
                if let i = store.rfis.firstIndex(where: { $0.id == rfi.id }) {
                    store.rfis[i].syncStatus = .synced
                }
                store.rfis.removeAll { $0.isDeleted && $0.syncStatus == .synced }
            } catch {
                if let i = store.rfis.firstIndex(where: { $0.id == rfi.id }) {
                    store.rfis[i].syncStatus = .failed
                }
            }
        }
        store.saveRFIs()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Project Budgets
    // ─────────────────────────────────────────────────────────────────────────

    func pullProjectBudgets(role: UserRole) async {
        guard !role.isFieldRole && !role.isExternal else { return }
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, project_id: String
                let original_contract_value, contingency_amount: Double
                let lines_json: String?
            }
            let rows: [Row] = try await supabase
                .from(SupabaseTable.projectBudgets)
                .select()
                .eq("company_id", value: companyID.uuidString)
                .execute().value

            var merged = store.projectBudgets.filter {
                $0.syncStatus == .pending || $0.syncStatus == .local
            }
            for row in rows {
                guard let uuid   = UUID(uuidString: row.id),
                      let projID = UUID(uuidString: row.project_id) else { continue }
                var bud = ProjectBudget(projectID: projID)
                bud.id                    = uuid
                bud.originalContractValue = fromDouble(row.original_contract_value)
                bud.contingencyAmount     = fromDouble(row.contingency_amount)
                bud.lines                 = decodeJSON(row.lines_json, as: [ProjectBudgetLine].self) ?? []
                bud.syncStatus            = .synced
                merged.removeAll { $0.id == uuid }
                merged.append(bud)
            }
            store.projectBudgets = merged
            store.saveBudgets()
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    func pushPendingProjectBudgets() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.projectBudgets.filter { $0.syncStatus == .pending }
        guard !pending.isEmpty else { return }
        for bud in pending {
            do {
                struct Row: Codable {
                    let id, company_id, project_id: String
                    let original_contract_value, contingency_amount: Double
                    let lines_json: String?
                    let last_modified_by: String?
                }
                let row = Row(
                    id:                      bud.id.uuidString,
                    company_id:              companyID.uuidString,
                    project_id:              bud.projectID.uuidString,
                    original_contract_value: toDouble(bud.originalContractValue),
                    contingency_amount:      toDouble(bud.contingencyAmount),
                    lines_json:              jsonString(bud.lines),
                    last_modified_by:        bud.lastModifiedBy.isEmpty ? nil : bud.lastModifiedBy
                )
                try await supabase.from(SupabaseTable.projectBudgets).upsert(row).execute()
                if let i = store.projectBudgets.firstIndex(where: { $0.id == bud.id }) {
                    store.projectBudgets[i].syncStatus = .synced
                }
            } catch {
                if let i = store.projectBudgets.firstIndex(where: { $0.id == bud.id }) {
                    store.projectBudgets[i].syncStatus = .failed
                }
            }
        }
        store.saveBudgets()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Subcontractors
    // ─────────────────────────────────────────────────────────────────────────

    func pullSubcontractors(role: UserRole) async {
        guard !role.isFieldRole && !role.isExternal else { return }
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, company_name, status: String
                let trade, contact_name, contact_title, email, phone, address: String?
                let insurance_policy_number, wcb_account: String?
                let insurance_amount: Double?
                let insurance_expiry, wcb_expiry, cor_expiry: String?
                let wcb_clearance_letter_received, has_cor: Bool
                let rating: Int?
                let notes: String?
            }
            let rows: [Row] = try await supabase
                .from(SupabaseTable.subcontractors)
                .select()
                .eq("company_id", value: companyID.uuidString)
                .execute().value

            var merged = store.subcontractors.filter {
                $0.syncStatus == .pending || $0.syncStatus == .local
            }
            for row in rows {
                guard let uuid = UUID(uuidString: row.id) else { continue }
                var sub = Subcontractor(companyName: row.company_name)
                sub.id                         = uuid
                sub.status                     = SubcontractorStatus(rawValue: row.status) ?? .active
                sub.trade                      = row.trade
                sub.contactName                = row.contact_name
                sub.contactTitle               = row.contact_title
                sub.email                      = row.email
                sub.phone                      = row.phone
                sub.address                    = row.address
                sub.insurancePolicyNumber      = row.insurance_policy_number
                sub.insuranceAmount            = row.insurance_amount.map { Decimal($0) }
                sub.insuranceExpiry            = parseDate(row.insurance_expiry)
                sub.wcbAccount                 = row.wcb_account
                sub.wcbExpiry                  = parseDate(row.wcb_expiry)
                sub.wcbClearanceLetterReceived = row.wcb_clearance_letter_received
                sub.hasCOR                     = row.has_cor
                sub.corExpiry                  = parseDate(row.cor_expiry)
                sub.rating                     = row.rating
                sub.notes                      = row.notes
                sub.syncStatus                 = .synced
                merged.removeAll { $0.id == uuid }
                merged.append(sub)
            }
            store.subcontractors = merged
            store.saveSubcontractors()
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    func pushPendingSubcontractors() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.subcontractors.filter { $0.syncStatus == .pending }
        guard !pending.isEmpty else { return }
        for sub in pending {
            do {
                struct Row: Codable {
                    let id, company_id, company_name, status: String
                    let trade, contact_name, contact_title, email, phone, address: String?
                    let insurance_policy_number, wcb_account: String?
                    let insurance_amount: Double?
                    let insurance_expiry, wcb_expiry, cor_expiry: String?
                    let wcb_clearance_letter_received, has_cor: Bool
                    let rating: Int?
                    let notes, last_modified_by: String?
                }
                let row = Row(
                    id:                            sub.id.uuidString,
                    company_id:                    companyID.uuidString,
                    company_name:                  sub.companyName,
                    status:                        sub.status.rawValue,
                    trade:                         sub.trade,
                    contact_name:                  sub.contactName,
                    contact_title:                 sub.contactTitle,
                    email:                         sub.email,
                    phone:                         sub.phone,
                    address:                       sub.address,
                    insurance_policy_number:       sub.insurancePolicyNumber,
                    wcb_account:                   sub.wcbAccount,
                    insurance_amount:              sub.insuranceAmount.map { toDouble($0) },
                    insurance_expiry:              sub.insuranceExpiry.map { isoDateFmt.string(from: $0) },
                    wcb_expiry:                    sub.wcbExpiry.map       { isoDateFmt.string(from: $0) },
                    cor_expiry:                    sub.corExpiry.map       { isoDateFmt.string(from: $0) },
                    wcb_clearance_letter_received: sub.wcbClearanceLetterReceived,
                    has_cor:                       sub.hasCOR,
                    rating:                        sub.rating,
                    notes:                         sub.notes,
                    last_modified_by:              sub.lastModifiedBy.isEmpty ? nil : sub.lastModifiedBy
                )
                try await supabase.from(SupabaseTable.subcontractors).upsert(row).execute()
                if let i = store.subcontractors.firstIndex(where: { $0.id == sub.id }) {
                    store.subcontractors[i].syncStatus = .synced
                }
            } catch {
                if let i = store.subcontractors.firstIndex(where: { $0.id == sub.id }) {
                    store.subcontractors[i].syncStatus = .failed
                }
            }
        }
        store.saveSubcontractors()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Sub-Contracts
    // ─────────────────────────────────────────────────────────────────────────

    func pullSubContracts(role: UserRole) async {
        guard !role.isFieldRole && !role.isExternal else { return }
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, contract_number, subcontractor_id, project_id, status: String
                let scope: String?
                let contract_value, retention_percent, invoiced_to_date, paid_to_date: Double
                let start_date, end_date, executed_date: String?
                let payment_terms, notes: String?
                /// Phase-2 deferred audit fix: forward link to a full
                /// Contract row when this SubContract has been promoted.
                let linked_contract_id: String?
            }
            let rows: [Row] = try await supabase
                .from(SupabaseTable.subContracts)
                .select()
                .eq("company_id", value: companyID.uuidString)
                .execute().value

            var merged = store.subContracts.filter {
                $0.syncStatus == .pending || $0.syncStatus == .local
            }
            for row in rows {
                guard let uuid   = UUID(uuidString: row.id),
                      let subID  = UUID(uuidString: row.subcontractor_id),
                      let projID = UUID(uuidString: row.project_id) else { continue }
                var sc = SubContract(contractNumber: row.contract_number,
                                     subcontractorID: subID,
                                     projectID: projID)
                sc.id               = uuid
                sc.status           = SubContractStatus(rawValue: row.status) ?? .draft
                sc.scope            = row.scope ?? ""
                sc.contractValue    = fromDouble(row.contract_value)
                sc.retentionPercent = fromDouble(row.retention_percent)
                sc.invoicedToDate   = fromDouble(row.invoiced_to_date)
                sc.paidToDate       = fromDouble(row.paid_to_date)
                sc.startDate        = parseDate(row.start_date)
                sc.endDate          = parseDate(row.end_date)
                sc.executedDate     = parseDate(row.executed_date)
                sc.paymentTerms     = row.payment_terms
                sc.notes            = row.notes
                sc.linkedContractID = row.linked_contract_id.flatMap { UUID(uuidString: $0) }
                sc.syncStatus       = .synced
                merged.removeAll { $0.id == uuid }
                merged.append(sc)
            }
            store.subContracts = merged
            store.saveSubContracts()
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    func pushPendingSubContracts() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.subContracts.filter { $0.syncStatus == .pending }
        guard !pending.isEmpty else { return }
        for sc in pending {
            do {
                struct Row: Codable {
                    let id, company_id, contract_number, subcontractor_id, project_id, status: String
                    let scope: String?
                    let contract_value, retention_percent, invoiced_to_date, paid_to_date: Double
                    let start_date, end_date, executed_date: String?
                    let payment_terms, notes, last_modified_by: String?
                    let linked_contract_id: String?
                }
                let row = Row(
                    id:                sc.id.uuidString,
                    company_id:        companyID.uuidString,
                    contract_number:   sc.contractNumber,
                    subcontractor_id:  sc.subcontractorID.uuidString,
                    project_id:        sc.projectID.uuidString,
                    status:            sc.status.rawValue,
                    scope:             sc.scope.isEmpty ? nil : sc.scope,
                    contract_value:    toDouble(sc.contractValue),
                    retention_percent: toDouble(sc.retentionPercent),
                    invoiced_to_date:  toDouble(sc.invoicedToDate),
                    paid_to_date:      toDouble(sc.paidToDate),
                    start_date:        sc.startDate.map    { isoDateFmt.string(from: $0) },
                    end_date:          sc.endDate.map      { isoDateFmt.string(from: $0) },
                    executed_date:     sc.executedDate.map { isoDateFmt.string(from: $0) },
                    payment_terms:     sc.paymentTerms,
                    notes:             sc.notes,
                    last_modified_by:  sc.lastModifiedBy.isEmpty ? nil : sc.lastModifiedBy,
                    linked_contract_id: sc.linkedContractID?.uuidString
                )
                try await supabase.from(SupabaseTable.subContracts).upsert(row).execute()
                if let i = store.subContracts.firstIndex(where: { $0.id == sc.id }) {
                    store.subContracts[i].syncStatus = .synced
                }
            } catch {
                if let i = store.subContracts.firstIndex(where: { $0.id == sc.id }) {
                    store.subContracts[i].syncStatus = .failed
                }
            }
        }
        store.saveSubContracts()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Invoices
    // ─────────────────────────────────────────────────────────────────────────

    func pullInvoices(role: UserRole) async {
        guard !role.isFieldRole && !role.isExternal else { return }
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, invoice_number, status: String
                let project_id, client_id: String?
                let bill_to_name, bill_to_address: String?
                let tax_rate: Double
                let invoice_date, due_date: String?
                let sent_at, paid_at: String?
                let terms, notes, po_number: String?
                let line_items_json, payments_json: String?
                let company_id: String?
                // Phase 7 audit fix
                let invoice_type: String?
                let quote_id: String?
                let locked_from_tax_rate: Double?
                /// 2026-04 re-audit fix: ISO 4217. NOT NULL in DB with
                /// default 'USD'.
                let currency: String?
            }
            let rows: [Row] = try await supabase
                .from(SupabaseTable.invoices)
                .select()
                .eq("company_id", value: companyID.uuidString)
                .eq("is_deleted", value: false)
                .order("created_at", ascending: false)
                .limit(200)
                .execute().value

            var merged = store.invoices.filter {
                $0.syncStatus == .pending || $0.syncStatus == .local
            }
            for row in rows {
                guard let uuid = UUID(uuidString: row.id) else { continue }
                var inv = Invoice(
                    invoiceNumber: row.invoice_number,
                    projectID: row.project_id.flatMap { UUID(uuidString: $0) }
                )
                inv.id           = uuid
                inv.companyID    = row.company_id.flatMap(UUID.init(uuidString:))
                inv.status       = InvoiceStatus(rawValue: row.status) ?? .draft
                inv.clientID     = row.client_id.flatMap { UUID(uuidString: $0) }
                inv.billToName   = row.bill_to_name    ?? ""
                inv.billToAddress = row.bill_to_address ?? ""
                inv.taxRate      = fromDouble(row.tax_rate)
                inv.invoiceDate  = parseDate(row.invoice_date) ?? Date()
                inv.dueDate      = parseDate(row.due_date)     ?? inv.dueDate
                inv.sentAt       = parseDate(row.sent_at)
                inv.paidAt       = parseDate(row.paid_at)
                inv.terms        = row.terms    ?? "Net 30"
                inv.notes        = row.notes    ?? ""
                inv.poNumber     = row.po_number ?? ""
                inv.lineItems    = decodeJSON(row.line_items_json, as: [InvoiceLineItem].self) ?? []
                inv.payments     = decodeJSON(row.payments_json,   as: [InvoicePayment].self)  ?? []
                inv.invoiceType  = row.invoice_type.flatMap { InvoiceType(rawValue: $0) } ?? .standard
                inv.quoteID      = row.quote_id.flatMap { UUID(uuidString: $0) }
                inv.lockedFromTaxRate = row.locked_from_tax_rate.map { Decimal($0) }
                inv.currency     = row.currency ?? "USD"
                inv.syncStatus   = .synced
                merged.removeAll { $0.id == uuid }
                merged.append(inv)
            }
            store.invoices = merged
            store.saveInvoices()
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    func pushPendingInvoices() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.invoices.filter { $0.syncStatus == .pending }
        guard !pending.isEmpty else { return }
        for inv in pending {
            do {
                struct Row: Codable {
                    let id, company_id, invoice_number, status: String
                    let project_id, client_id: String?
                    let bill_to_name, bill_to_address: String?
                    let tax_rate: Double
                    let invoice_date, due_date: String?
                    let sent_at, paid_at: String?
                    let terms, notes, po_number: String?
                    let line_items_json, payments_json: String?
                    let last_modified_by: String?
                    let is_deleted: Bool
                    let deleted_at: String?
                    let deleted_by: String?
                    // Phase 7 audit fix
                    let invoice_type: String
                    let quote_id: String?
                    let locked_from_tax_rate: Double?
                    /// 2026-04 re-audit fix.
                    let currency: String
                }
                let row = Row(
                    id:               inv.id.uuidString,
                    company_id:       companyID.uuidString,
                    invoice_number:   inv.invoiceNumber,
                    status:           inv.status.rawValue,
                    project_id:       inv.projectID?.uuidString,
                    client_id:        inv.clientID?.uuidString,
                    bill_to_name:     inv.billToName.isEmpty    ? nil : inv.billToName,
                    bill_to_address:  inv.billToAddress.isEmpty ? nil : inv.billToAddress,
                    tax_rate:         toDouble(inv.taxRate),
                    invoice_date:     isoDateFmt.string(from: inv.invoiceDate),
                    due_date:         isoDateFmt.string(from: inv.dueDate),
                    sent_at:          inv.sentAt.map { isoFull.string(from: $0) },
                    paid_at:          inv.paidAt.map  { isoFull.string(from: $0) },
                    terms:            inv.terms.isEmpty   ? nil : inv.terms,
                    notes:            inv.notes.isEmpty   ? nil : inv.notes,
                    po_number:        inv.poNumber.isEmpty ? nil : inv.poNumber,
                    line_items_json:  jsonString(inv.lineItems),
                    payments_json:    jsonString(inv.payments),
                    last_modified_by: inv.lastModifiedBy.isEmpty ? nil : inv.lastModifiedBy,
                    is_deleted:       inv.isDeleted,
                    deleted_at:       inv.deletedAt.map { isoFull.string(from: $0) },
                    deleted_by:       inv.deletedBy,
                    invoice_type:     inv.invoiceType.rawValue,
                    quote_id:         inv.quoteID?.uuidString,
                    locked_from_tax_rate: inv.lockedFromTaxRate.map { toDouble($0) },
                    currency:         inv.currency.isEmpty ? "USD" : inv.currency
                )
                try await supabase.from(SupabaseTable.invoices).upsert(row).execute()
                if let i = store.invoices.firstIndex(where: { $0.id == inv.id }) {
                    store.invoices[i].syncStatus = .synced
                }
                store.invoices.removeAll { $0.isDeleted && $0.syncStatus == .synced }
            } catch {
                if let i = store.invoices.firstIndex(where: { $0.id == inv.id }) {
                    store.invoices[i].syncStatus = .failed
                }
            }
        }
        store.saveInvoices()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Procurement  (Suppliers · Material Requests · Purchase Orders)
    // ─────────────────────────────────────────────────────────────────────────

    func pullProcurement(role: UserRole) async {
        // Workflow settings drive the Submit/Approve/Send/Receive button
        // gating in MR + PO flows, so they need to be hydrated before any
        // procurement view renders. Pulled even for field roles because
        // `canCreateMaterialRequest` is itself a workflow setting.
        await pullWorkflowSettings()
        guard !role.isFieldRole && !role.isExternal else { return }
        await pullSuppliers()
        await pullMaterialRequests()
        await pullPurchaseOrders()
        // Audit history depends on the requests being present locally so the
        // History section can resolve materialRequestID → request. Pulled
        // last for that reason.
        await pullMaterialRequestAudit()
    }

    // MARK: Material Request Audit (read-only; written by DB trigger)

    /// Hydrate the audit history for the current company. Pull-only model:
    /// rows are written exclusively by log_material_request_status_change,
    /// never by the client, so we replace the local cache wholesale on each
    /// pull. Bounded by status flips per request × requests per company —
    /// typically small enough to pull in one page. If this ever grows, add
    /// a `gt: performed_at` filter against the most recent local row.
    func pullMaterialRequestAudit() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id: String
                let company_id: String
                let material_request_id: String
                let action: String
                let performed_by: String?
                let performed_at: String
                let old_status: String?
                let new_status: String?
                let metadata: AnyJSON?
            }
            let rows: [Row] = try await supabase
                .from(SupabaseTable.materialRequestAudit)
                .select()
                .eq("company_id", value: companyID.uuidString)
                .order("performed_at", ascending: false)
                .execute().value

            let events: [MaterialRequestAudit] = rows.compactMap { row in
                guard let id  = UUID(uuidString: row.id),
                      let cid = UUID(uuidString: row.company_id),
                      let mrid = UUID(uuidString: row.material_request_id) else { return nil }
                let perfAt = parseDate(row.performed_at) ?? Date()
                let metadataData = (try? JSONEncoder().encode(row.metadata)) ?? Data()
                return MaterialRequestAudit(
                    id:                id,
                    companyID:         cid,
                    materialRequestID: mrid,
                    action:            row.action,
                    performedByID:     row.performed_by.flatMap { UUID(uuidString: $0) },
                    performedAt:       perfAt,
                    oldStatus:         row.old_status,
                    newStatus:         row.new_status,
                    metadataRaw:       metadataData
                )
            }
            await MainActor.run {
                store.materialRequestAudits = events
                store.objectWillChange.send()
            }
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    // MARK: Workflow Settings (approval limits per role per company)

    /// Push a single workflow_settings row to Supabase. Called by
    /// AppStore.upsertWorkflowSetting when the admin saves a change. Single
    /// row at a time because admin edits are rare and unbatched — no need
    /// for a pending-set + bulk push pattern.
    func pushPendingWorkflowSettings(_ setting: WorkflowSetting) async {
        do {
            struct Row: Codable {
                let id, company_id, role_key: String
                let approval_limit_amount: Decimal
                let can_self_approve: Bool
                let can_create_material_request: Bool
                let can_approve_material_request: Bool
                let can_send_to_supplier: Bool
                let can_receive_materials: Bool
                let is_active: Bool
                let updated_at: String
            }
            let row = Row(
                id:                            setting.id.uuidString,
                company_id:                    setting.companyID.uuidString,
                role_key:                      setting.roleKey,
                approval_limit_amount:         setting.approvalLimitAmount,
                can_self_approve:              setting.canSelfApprove,
                can_create_material_request:   setting.canCreateMaterialRequest,
                can_approve_material_request:  setting.canApproveMaterialRequest,
                can_send_to_supplier:          setting.canSendToSupplier,
                can_receive_materials:         setting.canReceiveMaterials,
                is_active:                     setting.isActive,
                updated_at:                    isoFull.string(from: setting.updatedAt)
            )
            // ON CONFLICT (company_id, role_key) — the migration creates a
            // unique constraint on this pair, so upsert resolves to update.
            try await supabase
                .from(SupabaseTable.workflowSettings)
                .upsert(row, onConflict: "company_id,role_key")
                .execute()
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
            await MainActor.run {
                ToastService.shared.error("Couldn't save workflow setting: \(error.localizedDescription)")
            }
        }
    }

    /// Hydrate workflow_settings for the current company. Replaces the local
    /// cache wholesale because rows are admin-managed in the DB — there are
    /// no pending local writes to merge in.
    func pullWorkflowSettings() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id: String
                let company_id: String
                let role_key: String
                let approval_limit_amount: Decimal
                let can_self_approve: Bool
                let can_create_material_request: Bool
                let can_approve_material_request: Bool
                let can_send_to_supplier: Bool
                let can_receive_materials: Bool
                let is_active: Bool
                let updated_at: String?
            }
            let rows: [Row] = try await supabase
                .from(SupabaseTable.workflowSettings)
                .select()
                .eq("company_id", value: companyID.uuidString)
                .eq("is_active", value: true)
                .execute().value

            let settings: [WorkflowSetting] = rows.compactMap { row in
                guard let id  = UUID(uuidString: row.id),
                      let cid = UUID(uuidString: row.company_id) else { return nil }
                return WorkflowSetting(
                    id:                            id,
                    companyID:                     cid,
                    roleKey:                       row.role_key,
                    approvalLimitAmount:           row.approval_limit_amount,
                    canSelfApprove:                row.can_self_approve,
                    canCreateMaterialRequest:      row.can_create_material_request,
                    canApproveMaterialRequest:     row.can_approve_material_request,
                    canSendToSupplier:             row.can_send_to_supplier,
                    canReceiveMaterials:           row.can_receive_materials,
                    isActive:                      row.is_active,
                    updatedAt:                     parseDate(row.updated_at) ?? Date()
                )
            }
            await MainActor.run {
                store.workflowSettings = settings
                store.objectWillChange.send()
            }
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    func pushPendingProcurement() async {
        await pushPendingSuppliers()      // now uses syncStatus filter
        await pushPendingMaterialRequests()
        await pushPendingPurchaseOrders()
    }

    // MARK: Suppliers

    private func pullSuppliers() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, name: String
                let contact_name, phone, email, address: String?
                let account_number, notes: String?
                let is_preferred: Bool
                let updated_at: String?
            }
            let rows: [Row] = try await supabase
                .from(SupabaseTable.suppliers)
                .select()
                .eq("company_id", value: companyID.uuidString)
                .eq("is_deleted", value: false)
                .execute().value

            var merged = store.suppliers.filter {
                $0.syncStatus == .pending || $0.syncStatus == .local
            }
            for row in rows {
                guard let uuid = UUID(uuidString: row.id) else { continue }
                var sup = Supplier(name: row.name)
                sup.id            = uuid
                sup.contactName   = row.contact_name   ?? ""
                sup.phone         = row.phone          ?? ""
                sup.email         = row.email          ?? ""
                sup.address       = row.address        ?? ""
                sup.accountNumber = row.account_number ?? ""
                sup.notes         = row.notes          ?? ""
                sup.isPreferred   = row.is_preferred
                sup.updatedAt     = parseDate(row.updated_at) ?? Date()
                sup.syncStatus    = .synced
                merged.removeAll { $0.id == uuid }
                merged.append(sup)
            }
            store.suppliers = merged
            store.objectWillChange.send()
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    func pushPendingSuppliers() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.suppliers.filter { $0.syncStatus == .pending || $0.syncStatus == .local }
        guard !pending.isEmpty else { return }
        for sup in pending {
            do {
                struct Row: Codable {
                    let id, company_id, name: String
                    let contact_name, phone, email, address: String?
                    let account_number, notes, last_modified_by: String?
                    let is_preferred: Bool
                    let updated_at: String
                    let is_deleted: Bool
                    let deleted_at: String?
                    let deleted_by: String?
                }
                let row = Row(
                    id:               sup.id.uuidString,
                    company_id:       (sup.companyID ?? companyID).uuidString,
                    name:             sup.name,
                    contact_name:     sup.contactName.isEmpty   ? nil : sup.contactName,
                    phone:            sup.phone.isEmpty         ? nil : sup.phone,
                    email:            sup.email.isEmpty         ? nil : sup.email,
                    address:          sup.address.isEmpty       ? nil : sup.address,
                    account_number:   sup.accountNumber.isEmpty ? nil : sup.accountNumber,
                    notes:            sup.notes.isEmpty         ? nil : sup.notes,
                    last_modified_by: sup.lastModifiedBy.isEmpty ? nil : sup.lastModifiedBy,
                    is_preferred:     sup.isPreferred,
                    updated_at:       isoFull.string(from: sup.updatedAt),
                    is_deleted:       sup.isDeleted,
                    deleted_at:       sup.deletedAt.map { isoFull.string(from: $0) },
                    deleted_by:       sup.deletedBy
                )
                try await supabase.from(SupabaseTable.suppliers).upsert(row).execute()
                if let i = store.suppliers.firstIndex(where: { $0.id == sup.id }) {
                    store.suppliers[i].syncStatus = .synced
                }
                store.suppliers.removeAll { $0.isDeleted && $0.syncStatus == .synced }
            } catch {
                if let i = store.suppliers.firstIndex(where: { $0.id == sup.id }) {
                    store.suppliers[i].syncStatus = .failed
                }
            }
        }
    }

    // MARK: Material Requests

    private func pullMaterialRequests() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, request_number, status: String
                let project_id, supplier_id, material_sales_id, requested_by_employee_id: String?
                let destination_type: String?
                let requested_by_name, requested_by_email: String?
                let request_date, required_by_date: String?
                let notes, site_location: String?
                let line_items_json: String?
                // Audit fields
                let submitted_by_user_id, approved_by_user_id, received_by_user_id: String?
                let submitted_at, approved_at, ordered_at, received_at, closed_at: String?
                let approval_note: String?
                // PDF tracking
                let pdf_storage_path: String?
                let pdf_generated_at: String?
                // Delivery proof + reference scan
                let delivery_photo_url: String?
                let receipt_scan_path: String?
            }
            let rows: [Row] = try await supabase
                .from(SupabaseTable.materialRequests)
                .select()
                .eq("company_id", value: companyID.uuidString)
                .eq("is_deleted", value: false)
                .execute().value

            var merged = store.materialRequests.filter {
                $0.syncStatus == .pending || $0.syncStatus == .local
            }
            for row in rows {
                guard let uuid = UUID(uuidString: row.id) else { continue }
                let projID = row.project_id.flatMap { UUID(uuidString: $0) }
                var mr = MaterialRequest(requestNumber: row.request_number, projectID: projID)
                mr.id               = uuid
                mr.status           = MaterialRequestStatus(rawValue: row.status) ?? .draft
                mr.destinationType  = row.destination_type
                    .flatMap { MaterialRequestDestinationType(rawValue: $0) } ?? .internalUse
                mr.materialSaleID   = row.material_sales_id.flatMap { UUID(uuidString: $0) }
                mr.supplierID       = row.supplier_id.flatMap { UUID(uuidString: $0) }
                mr.requestedByID    = row.requested_by_employee_id.flatMap { UUID(uuidString: $0) }
                mr.requestedByName  = row.requested_by_name ?? ""
                mr.requestedByEmail = row.requested_by_email
                mr.requestDate      = parseDate(row.request_date) ?? Date()
                mr.requiredByDate   = parseDate(row.required_by_date)
                mr.notes            = row.notes ?? ""
                mr.siteLocation     = row.site_location ?? ""
                mr.lineItems        = decodeJSON(row.line_items_json, as: [MaterialLineItem].self) ?? []
                mr.submittedByID    = row.submitted_by_user_id.flatMap { UUID(uuidString: $0) }
                mr.submittedAt      = parseDate(row.submitted_at)
                mr.approvedByID     = row.approved_by_user_id.flatMap { UUID(uuidString: $0) }
                mr.approvedAt       = parseDate(row.approved_at)
                mr.approvalNote     = row.approval_note ?? ""
                mr.orderedAt        = parseDate(row.ordered_at)
                mr.receivedByID     = row.received_by_user_id.flatMap { UUID(uuidString: $0) }
                mr.receivedAt       = parseDate(row.received_at)
                mr.closedAt         = parseDate(row.closed_at)
                mr.pdfStoragePath   = row.pdf_storage_path
                mr.pdfGeneratedAt   = parseDate(row.pdf_generated_at)
                mr.deliveryPhotoURL = row.delivery_photo_url
                mr.receiptScanPath  = row.receipt_scan_path
                mr.syncStatus       = .synced
                merged.removeAll { $0.id == uuid }
                merged.append(mr)
            }
            store.materialRequests = merged
            store.saveMaterialRequests()
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    func pushPendingMaterialRequests() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.materialRequests.filter { $0.syncStatus == .pending }
        guard !pending.isEmpty else { return }
        for mr in pending {
            do {
                struct Row: Codable {
                    let id, company_id, request_number, status: String
                    let destination_type: String
                    let project_id, supplier_id, material_sales_id, requested_by_employee_id: String?
                    let requested_by_name, requested_by_email: String?
                    let request_date, required_by_date: String?
                    let notes, site_location: String?
                    let line_items_json: String?
                    let total_estimated_cost: Decimal
                    // Audit fields — set by the typed transition methods on
                    // AppStore. Pushing them so the DB trigger captures
                    // who/when in material_request_audit metadata.
                    let submitted_by_user_id, approved_by_user_id, received_by_user_id: String?
                    let submitted_at, approved_at, ordered_at, received_at, closed_at: String?
                    let approval_note: String?
                    let pdf_storage_path: String?
                    let pdf_generated_at: String?
                    let delivery_photo_url: String?
                    let receipt_scan_path: String?
                    let is_deleted: Bool
                    let deleted_at: String?
                    let deleted_by: String?
                }
                let row = Row(
                    id:                mr.id.uuidString,
                    company_id:        (mr.companyID ?? companyID).uuidString,
                    request_number:    mr.requestNumber,
                    status:            mr.status.rawValue,
                    destination_type:  mr.destinationType.rawValue,
                    project_id:        mr.projectID?.uuidString,
                    supplier_id:       mr.supplierID?.uuidString,
                    material_sales_id: mr.materialSaleID?.uuidString,
                    requested_by_employee_id: mr.requestedByID?.uuidString,
                    requested_by_name:  mr.requestedByName.isEmpty ? nil : mr.requestedByName,
                    requested_by_email: mr.requestedByEmail,
                    request_date:      isoDateFmt.string(from: mr.requestDate),
                    required_by_date:  mr.requiredByDate.map { isoDateFmt.string(from: $0) },
                    notes:             mr.notes.isEmpty        ? nil : mr.notes,
                    site_location:     mr.siteLocation.isEmpty ? nil : mr.siteLocation,
                    line_items_json:   jsonString(mr.lineItems),
                    // Push the client-computed total so the DB column reflects
                    // the canonical value even before child-table sync lands.
                    // The recalc trigger preserves this on no-children updates;
                    // it'll naturally take over once children exist (Phase 3).
                    total_estimated_cost: mr.estimatedTotal,
                    submitted_by_user_id: mr.submittedByID?.uuidString,
                    approved_by_user_id:  mr.approvedByID?.uuidString,
                    received_by_user_id:  mr.receivedByID?.uuidString,
                    submitted_at:      mr.submittedAt.map { isoFull.string(from: $0) },
                    approved_at:       mr.approvedAt.map  { isoFull.string(from: $0) },
                    ordered_at:        mr.orderedAt.map   { isoFull.string(from: $0) },
                    received_at:       mr.receivedAt.map  { isoFull.string(from: $0) },
                    closed_at:         mr.closedAt.map    { isoFull.string(from: $0) },
                    approval_note:     mr.approvalNote.isEmpty ? nil : mr.approvalNote,
                    pdf_storage_path:  mr.pdfStoragePath,
                    pdf_generated_at:  mr.pdfGeneratedAt.map { isoFull.string(from: $0) },
                    delivery_photo_url: mr.deliveryPhotoURL,
                    receipt_scan_path:  mr.receiptScanPath,
                    is_deleted:        mr.isDeleted,
                    deleted_at:        mr.deletedAt.map { isoFull.string(from: $0) },
                    deleted_by:        mr.deletedBy
                )
                try await supabase.from(SupabaseTable.materialRequests).upsert(row).execute()
                if let i = store.materialRequests.firstIndex(where: { $0.id == mr.id }) {
                    store.materialRequests[i].syncStatus = .synced
                }
                store.materialRequests.removeAll { $0.isDeleted && $0.syncStatus == .synced }
            } catch {
                if let i = store.materialRequests.firstIndex(where: { $0.id == mr.id }) {
                    store.materialRequests[i].syncStatus = .failed
                }
            }
        }
        store.saveMaterialRequests()
    }

    // MARK: Purchase Orders

    private func pullPurchaseOrders() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, po_number, status: String
                let project_id, supplier_id: String?
                let supplier_name: String?
                let issue_date, required_date, received_date: String?
                let delivery_address, terms, notes: String?
                let tax_rate: Double
                let line_items_json: String?
                let delivery_photo_url: String?
                // Invoice match (Phase 3)
                let invoice_number, invoice_scan_path, invoice_match_note: String?
                let invoice_date: String?
                let invoice_amount: Decimal?
                let invoice_matched_at: String?
                let invoice_matched_by: String?
                let invoice_flagged: Bool?
            }
            let rows: [Row] = try await supabase
                .from(SupabaseTable.purchaseOrders)
                .select()
                .eq("company_id", value: companyID.uuidString)
                .eq("is_deleted", value: false)
                .execute().value

            var merged = store.purchaseOrders.filter {
                $0.syncStatus == .pending || $0.syncStatus == .local
            }
            for row in rows {
                guard let uuid = UUID(uuidString: row.id) else { continue }
                let projID = row.project_id.flatMap { UUID(uuidString: $0) }
                var po = PurchaseOrder(poNumber: row.po_number, projectID: projID)
                po.id              = uuid
                po.status          = POStatus(rawValue: row.status) ?? .draft
                po.supplierID      = row.supplier_id.flatMap { UUID(uuidString: $0) }
                po.supplierName    = row.supplier_name   ?? ""
                po.issueDate       = parseDate(row.issue_date) ?? Date()
                po.requiredDate    = parseDate(row.required_date)
                po.receivedDate    = parseDate(row.received_date)
                po.deliveryAddress = row.delivery_address ?? ""
                po.terms           = row.terms ?? ""
                po.notes           = row.notes ?? ""
                po.taxRate         = fromDouble(row.tax_rate)
                po.lineItems       = decodeJSON(row.line_items_json, as: [MaterialLineItem].self) ?? []
                po.deliveryPhotoURL = row.delivery_photo_url
                po.invoiceNumber    = row.invoice_number
                po.invoiceDate      = parseDate(row.invoice_date)
                po.invoiceAmount    = row.invoice_amount
                po.invoiceScanPath  = row.invoice_scan_path
                po.invoiceMatchedAt = parseDate(row.invoice_matched_at)
                po.invoiceMatchedBy = row.invoice_matched_by.flatMap { UUID(uuidString: $0) }
                po.invoiceMatchNote = row.invoice_match_note
                po.invoiceFlagged   = row.invoice_flagged ?? false
                po.syncStatus      = .synced
                merged.removeAll { $0.id == uuid }
                merged.append(po)
            }
            store.purchaseOrders = merged
            store.savePurchaseOrders()
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    func pushPendingPurchaseOrders() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.purchaseOrders.filter { $0.syncStatus == .pending }
        guard !pending.isEmpty else { return }
        for po in pending {
            do {
                struct Row: Codable {
                    let id, company_id, po_number, status: String
                    let project_id, supplier_id, supplier_name: String?
                    let issue_date, required_date, received_date: String?
                    let delivery_address, terms, notes: String?
                    let tax_rate: Double
                    let line_items_json: String?
                    let delivery_photo_url: String?
                    let invoice_number, invoice_scan_path, invoice_match_note: String?
                    let invoice_date: String?
                    let invoice_amount: Decimal?
                    let invoice_matched_at: String?
                    let invoice_matched_by: String?
                    let invoice_flagged: Bool
                    let is_deleted: Bool
                    let deleted_at: String?
                    let deleted_by: String?
                }
                let row = Row(
                    id:               po.id.uuidString,
                    company_id:       (po.companyID ?? companyID).uuidString,
                    po_number:        po.poNumber,
                    status:           po.status.rawValue,
                    project_id:       po.projectID?.uuidString,
                    supplier_id:      po.supplierID?.uuidString,
                    supplier_name:    po.supplierName.isEmpty ? nil : po.supplierName,
                    issue_date:       isoDateFmt.string(from: po.issueDate),
                    required_date:    po.requiredDate.map  { isoDateFmt.string(from: $0) },
                    received_date:    po.receivedDate.map  { isoDateFmt.string(from: $0) },
                    delivery_address: po.deliveryAddress.isEmpty ? nil : po.deliveryAddress,
                    terms:            po.terms.isEmpty    ? nil : po.terms,
                    notes:            po.notes.isEmpty    ? nil : po.notes,
                    tax_rate:         toDouble(po.taxRate),
                    line_items_json:  jsonString(po.lineItems),
                    delivery_photo_url: po.deliveryPhotoURL,
                    invoice_number:    po.invoiceNumber,
                    invoice_scan_path: po.invoiceScanPath,
                    invoice_match_note: po.invoiceMatchNote,
                    invoice_date:      po.invoiceDate.map { isoDateFmt.string(from: $0) },
                    invoice_amount:    po.invoiceAmount,
                    invoice_matched_at: po.invoiceMatchedAt.map { isoFull.string(from: $0) },
                    invoice_matched_by: po.invoiceMatchedBy?.uuidString,
                    invoice_flagged:   po.invoiceFlagged,
                    is_deleted:       po.isDeleted,
                    deleted_at:       po.deletedAt.map { isoFull.string(from: $0) },
                    deleted_by:       po.deletedBy
                )
                try await supabase.from(SupabaseTable.purchaseOrders).upsert(row).execute()
                if let i = store.purchaseOrders.firstIndex(where: { $0.id == po.id }) {
                    store.purchaseOrders[i].syncStatus = .synced
                }
                store.purchaseOrders.removeAll { $0.isDeleted && $0.syncStatus == .synced }
            } catch {
                if let i = store.purchaseOrders.firstIndex(where: { $0.id == po.id }) {
                    store.purchaseOrders[i].syncStatus = .failed
                }
            }
        }
        store.savePurchaseOrders()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Product & Service Library
    // ─────────────────────────────────────────────────────────────────────────

    func pullProductServices() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, name, type, cost_code, description, unit, category: String
                let default_price: Double
                let is_active: Bool
                let sort_order: Int
                let company_id: String?
            }
            let rows: [Row] = try await supabase
                .from(SupabaseTable.productServices)
                .select()
                .eq("company_id", value: companyID.uuidString)
                .order("sort_order")
                .execute().value

            var merged = store.productServices.filter {
                $0.syncStatus == .pending || $0.syncStatus == .local
            }
            for row in rows {
                guard let uuid = UUID(uuidString: row.id) else { continue }
                var ps = ProductService(
                    name:         row.name,
                    type:         ProductServiceType(rawValue: row.type) ?? .service,
                    costCode:     row.cost_code,
                    description:  row.description,
                    unit:         row.unit,
                    defaultPrice: fromDouble(row.default_price),
                    category:     CostCodeCategory(rawValue: row.category) ?? .labour
                )
                ps.id         = uuid
                ps.companyID  = row.company_id.flatMap(UUID.init(uuidString:))
                ps.isActive   = row.is_active
                ps.sortOrder  = row.sort_order
                ps.syncStatus = .synced
                merged.removeAll { $0.id == uuid }
                merged.append(ps)
            }
            store.productServices = merged
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    func pushPendingProductServices() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.productServices.filter { $0.syncStatus == .pending || $0.syncStatus == .local }
        guard !pending.isEmpty else { return }
        for ps in pending {
            do {
                struct Row: Encodable {
                    let id, company_id, name, type, cost_code, description, unit, category: String
                    let default_price: Double
                    let is_active: Bool
                    let sort_order: Int
                }
                let row = Row(
                    id:            ps.id.uuidString,
                    company_id:    companyID.uuidString,
                    name:          ps.name,
                    type:          ps.type.rawValue,
                    cost_code:     ps.costCode,
                    description:   ps.description,
                    unit:          ps.unit,
                    category:      ps.category.rawValue,
                    default_price: toDouble(ps.defaultPrice),
                    is_active:     ps.isActive,
                    sort_order:    ps.sortOrder
                )
                try await supabase.from(SupabaseTable.productServices).upsert(row).execute()
                if let i = store.productServices.firstIndex(where: { $0.id == ps.id }) {
                    store.productServices[i].syncStatus = .synced
                }
            } catch {
                if let i = store.productServices.firstIndex(where: { $0.id == ps.id }) {
                    store.productServices[i].syncStatus = .failed
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Client Pricings
    // ─────────────────────────────────────────────────────────────────────────

    func pullClientPricings() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, client_id, product_service_id: String
                let override_price: Double
                let notes: String?
            }
            let rows: [Row] = try await supabase
                .from(SupabaseTable.clientPricings)
                .select()
                .eq("company_id", value: companyID.uuidString)
                .execute().value

            var merged = store.clientPricings.filter {
                $0.syncStatus == .pending || $0.syncStatus == .local
            }
            for row in rows {
                guard let uuid = UUID(uuidString: row.id),
                      let cid  = UUID(uuidString: row.client_id),
                      let psid = UUID(uuidString: row.product_service_id) else { continue }
                var cp = ClientPricing(
                    clientID:         cid,
                    productServiceID: psid,
                    overridePrice:    fromDouble(row.override_price),
                    notes:            row.notes
                )
                cp.id         = uuid
                cp.syncStatus = .synced
                merged.removeAll { $0.id == uuid }
                merged.append(cp)
            }
            store.clientPricings = merged
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    func pushPendingClientPricings() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.clientPricings.filter { $0.syncStatus == .pending || $0.syncStatus == .local }
        guard !pending.isEmpty else { return }
        for cp in pending {
            do {
                struct Row: Encodable {
                    let id, company_id, client_id, product_service_id: String
                    let override_price: Double
                    let notes: String?
                }
                let row = Row(
                    id:                 cp.id.uuidString,
                    company_id:         companyID.uuidString,
                    client_id:          cp.clientID.uuidString,
                    product_service_id: cp.productServiceID.uuidString,
                    override_price:     toDouble(cp.overridePrice),
                    notes:              cp.notes
                )
                try await supabase.from(SupabaseTable.clientPricings).upsert(row).execute()
                if let i = store.clientPricings.firstIndex(where: { $0.id == cp.id }) {
                    store.clientPricings[i].syncStatus = .synced
                }
            } catch {
                if let i = store.clientPricings.firstIndex(where: { $0.id == cp.id }) {
                    store.clientPricings[i].syncStatus = .failed
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Clients — Pull & Push
    // ─────────────────────────────────────────────────────────────────────────

    func pushPendingClients() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.clients.filter { $0.syncStatus == .pending || $0.syncStatus == .local }
        guard !pending.isEmpty else { return }
        for client in pending {
            do {
                struct Row: Encodable {
                    let id, company_id, name: String
                    let code: String?
                    let contact_name: String?
                    let email: String?          // actual column name in Supabase clients table
                    let phone: String?          // actual column name in Supabase clients table
                    let billing_address, billing_city, billing_province, billing_postal: String?
                    let default_payment_terms: String?
                    let tax_exempt: Bool
                    let notes: String?
                    let is_active: Bool
                    let is_deleted: Bool
                    let deleted_at: String?
                    let deleted_by: String?
                    /// Stabilization fix: client sites were getting wiped on
                    /// every pull because the column didn't exist. Now stored
                    /// as JSON-encoded ClientSite[]. Matches the line_items_json
                    /// pattern used by estimates + quotes.
                    let sites_json: String
                    // Sample-data tracking
                    let is_sample_data: Bool
                    let sample_data_batch_id: String?
                    let sample_data_seed_version: String?
                    let sample_data_created_at: String?
                    let sample_data_created_by: String?
                }
                let sitesJSON: String = {
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    if let data = try? encoder.encode(client.sites),
                       let str = String(data: data, encoding: .utf8) {
                        return str
                    }
                    return "[]"
                }()
                let row = Row(
                    id:                    client.id.uuidString,
                    company_id:            companyID.uuidString,
                    name:                  client.name,
                    code:                  client.code,
                    contact_name:          client.contactName,
                    email:                 client.contactEmail,
                    phone:                 client.contactPhone,
                    billing_address:       client.billingAddress,
                    billing_city:          client.billingCity,
                    billing_province:      client.billingProvince,
                    billing_postal:        client.billingPostal,
                    default_payment_terms: client.defaultPaymentTerms,
                    tax_exempt:            client.taxExempt,
                    notes:                 client.notes,
                    is_active:             client.isActive,
                    is_deleted:            client.isDeleted,
                    deleted_at:            client.deletedAt.map { isoFull.string(from: $0) },
                    deleted_by:            client.deletedBy,
                    sites_json:               sitesJSON,
                    is_sample_data:           client.isSampleData,
                    sample_data_batch_id:     client.sampleDataBatchID?.uuidString,
                    sample_data_seed_version: client.sampleDataSeedVersion,
                    sample_data_created_at:   client.sampleDataCreatedAt.map { isoFull.string(from: $0) },
                    sample_data_created_by:   client.sampleDataCreatedBy?.uuidString
                )
                // DIAGNOSTIC: log what we're about to push so the
                // sites-persistence bug can be traced from the Xcode
                // console. Drop these prints once the issue is closed.
                print("📤 pushPendingClients: pushing \(client.name) — sites count = \(client.sites.count), sites_json length = \(sitesJSON.count)")
                if client.sites.isEmpty {
                    print("⚠️ pushPendingClients: \(client.name) has 0 sites locally — about to write empty sites_json. If you JUST added a site, something cleared client.sites between the add and this push.")
                }
                try await supabase.from(SupabaseTable.clients).upsert(row).execute()
                print("✅ pushPendingClients: \(client.name) synced (sites: \(client.sites.count))")
                var updated = client; updated.syncStatus = .synced
                store.upsertClientSynced(updated)
                store.clients.removeAll { $0.isDeleted && $0.syncStatus == .synced }
            } catch {
                // No more silent swallow — surface the actual error so
                // the user sees what RLS / column mismatch / network
                // hiccup blocked the push.
                print("❌ pushPendingClients: \(client.name) FAILED — \(error.localizedDescription)")
                print("❌ pushPendingClients: full error = \(error)")
                CrashReporter.capture(error: error, context: [
                    "operation": "pushPendingClients",
                    "client_id": client.id.uuidString,
                    "client_name": client.name,
                    "site_count": "\(client.sites.count)"
                ])
                var updated = client; updated.syncStatus = .failed
                store.upsertClientSynced(updated)
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Estimates — Pull & Push
    // ─────────────────────────────────────────────────────────────────────────

    func pullEstimates(role: UserRole) async {
        guard !role.isFieldRole && !role.isExternal else { return }
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, job_number, client_id, name, status: String
                let project_id, site_id, primary_contact_id: String?
                let opportunity_type, pricing_type: String
                let scope_description: String?
                let rfq_received_date, bid_due_date, submitted_date, awarded_date: String?
                let revision_number: Int
                let estimator_id: String?
                let internal_review_by, internal_notes, internal_approved_at: String?
                let loss_reason, competitor_name, win_loss_notes: String?
                let awarded_value: Double?
                let line_items_json: String?
                let contingency_percent, overhead_percent, profit_percent: Double
                let notes: String?
                let created_at, updated_at: String?
                let company_id: String?
                /// Set when the estimate has been converted to a quote.
                /// Pairs with `Estimate.convertedQuoteID` on iOS for
                /// bidirectional traceability. Added in the 2026-04
                /// Phase 3 audit fix; older rows return null.
                let converted_quote_id: String?
                // CRM linkage — added in 2026-05 estimates-schema fix.
                // Optional on decode so older rows that pre-date the
                // migration deserialize cleanly.
                let origin_type: String?
                let opportunity_id: String?
                /// Terms-defaults ledger (estimate_terms feature). Optional
                /// on decode so legacy rows pre-dating the migration
                /// deserialize cleanly.
                let terms_default_applied: Bool?
                // Sample-data tracking
                let is_sample_data: Bool?
                let sample_data_batch_id: String?
                let sample_data_seed_version: String?
                let sample_data_created_at: String?
                let sample_data_created_by: String?
            }
            let rows: [Row] = try await supabase
                .from(SupabaseTable.estimates)
                .select()
                .eq("company_id", value: companyID.uuidString)
                .order("created_at", ascending: false)
                .execute().value

            var merged = store.estimates.filter {
                $0.syncStatus == .pending || $0.syncStatus == .local
            }
            for row in rows {
                guard let uuid     = UUID(uuidString: row.id),
                      let clientID = UUID(uuidString: row.client_id) else { continue }
                var est = Estimate(jobNumber: row.job_number, clientID: clientID, name: row.name)
                est.id                  = uuid
                est.companyID           = row.company_id.flatMap(UUID.init(uuidString:))
                est.status              = EstimateStatus(rawValue: row.status)             ?? .estimating
                est.opportunityType     = OpportunityType(rawValue: row.opportunity_type)  ?? .rfq
                est.pricingType         = PricingType(rawValue: row.pricing_type)          ?? .lumpSum
                est.projectID           = row.project_id.flatMap          { UUID(uuidString: $0) }
                est.siteID              = row.site_id.flatMap             { UUID(uuidString: $0) }
                est.primaryContactID    = row.primary_contact_id.flatMap  { UUID(uuidString: $0) }
                est.estimatorID         = row.estimator_id.flatMap        { UUID(uuidString: $0) }
                est.scopeDescription    = row.scope_description
                est.rfqReceivedDate     = parseDate(row.rfq_received_date)
                est.bidDueDate          = parseDate(row.bid_due_date)
                est.submittedDate       = parseDate(row.submitted_date)
                est.awardedDate         = parseDate(row.awarded_date)
                est.revisionNumber      = row.revision_number
                est.internalReviewBy    = row.internal_review_by
                est.internalNotes       = row.internal_notes
                est.internalApprovedAt  = parseDate(row.internal_approved_at)
                est.lossReason          = row.loss_reason.flatMap        { LossReason(rawValue: $0) }
                est.competitorName      = row.competitor_name
                est.winLossNotes        = row.win_loss_notes
                est.awardedValue        = row.awarded_value.map           { Decimal($0) }
                est.lineItems           = decodeJSON(row.line_items_json, as: [CostCodeItem].self) ?? []
                est.contingencyPercent  = fromDouble(row.contingency_percent)
                est.overheadPercent     = fromDouble(row.overhead_percent)
                est.profitPercent       = fromDouble(row.profit_percent)
                est.notes               = row.notes
                est.convertedQuoteID    = row.converted_quote_id.flatMap { UUID(uuidString: $0) }
                est.originType          = row.origin_type
                                            .flatMap(CommercialOriginType.init(rawValue:))
                                            ?? .directCommercial
                est.opportunityID       = row.opportunity_id.flatMap { UUID(uuidString: $0) }
                est.termsDefaultApplied = row.terms_default_applied ?? false
                est.createdAt           = parseDate(row.created_at)    ?? Date()
                est.updatedAt           = parseDate(row.updated_at)    ?? Date()
                est.syncStatus          = .synced
                est.isSampleData          = row.is_sample_data ?? false
                est.sampleDataBatchID     = row.sample_data_batch_id.flatMap(UUID.init(uuidString:))
                est.sampleDataSeedVersion = row.sample_data_seed_version
                est.sampleDataCreatedAt   = parseDate(row.sample_data_created_at)
                est.sampleDataCreatedBy   = row.sample_data_created_by.flatMap(UUID.init(uuidString:))
                merged.removeAll { $0.id == uuid }
                merged.append(est)
            }
            store.estimates = merged
            store.objectWillChange.send()
        } catch {
            // Was previously a silent catch labelled "table may not exist
            // yet". That hid every schema-mismatch bug for months — when
            // pushPendingEstimates was rejecting columns server-side, this
            // pull also failed to decode and the UI reported "no estimates"
            // instead of the actual error. Log loudly so future drift is
            // visible the moment it happens.
            print("⚠️ pullEstimates failed: \(error)")
            CrashReporter.capture(error: error,
                                  context: ["operation": "pullEstimates"])
        }
    }

    func pushPendingEstimates() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.estimates.filter { $0.syncStatus == .pending }
        guard !pending.isEmpty else { return }
        for est in pending {
            do {
                struct Row: Encodable {
                    let id, company_id, job_number, client_id, name, status: String
                    let project_id, site_id, primary_contact_id, estimator_id: String?
                    let opportunity_type, pricing_type: String
                    let scope_description: String?
                    let rfq_received_date, bid_due_date, submitted_date, awarded_date: String?
                    let converted_quote_id: String?
                    let revision_number: Int
                    let internal_review_by, internal_notes, internal_approved_at: String?
                    let loss_reason, competitor_name, win_loss_notes: String?
                    let awarded_value: Double?
                    let line_items_json: String?
                    let contingency_percent, overhead_percent, profit_percent: Double
                    let notes, last_modified_by: String?
                    let created_at, updated_at: String
                    // CRM linkage — added in 2026-05 estimates-schema fix
                    let origin_type: String
                    let opportunity_id: String?
                    /// estimate_terms ledger flag.
                    let terms_default_applied: Bool
                    // Sample-data tracking
                    let is_sample_data: Bool
                    let sample_data_batch_id: String?
                    let sample_data_seed_version: String?
                    let sample_data_created_at: String?
                    let sample_data_created_by: String?
                }
                let row = Row(
                    id:                    est.id.uuidString,
                    company_id:            companyID.uuidString,
                    job_number:            est.jobNumber,
                    client_id:             est.clientID.uuidString,
                    name:                  est.name,
                    status:                est.status.rawValue,
                    project_id:            est.projectID?.uuidString,
                    site_id:               est.siteID?.uuidString,
                    primary_contact_id:    est.primaryContactID?.uuidString,
                    estimator_id:          est.estimatorID?.uuidString,
                    opportunity_type:      est.opportunityType.rawValue,
                    pricing_type:          est.pricingType.rawValue,
                    scope_description:     est.scopeDescription,
                    rfq_received_date:     est.rfqReceivedDate.map     { isoFull.string(from: $0) },
                    bid_due_date:          est.bidDueDate.map          { isoFull.string(from: $0) },
                    submitted_date:        est.submittedDate.map       { isoFull.string(from: $0) },
                    awarded_date:          est.awardedDate.map         { isoFull.string(from: $0) },
                    converted_quote_id:    est.convertedQuoteID?.uuidString,
                    revision_number:       est.revisionNumber,
                    internal_review_by:    est.internalReviewBy,
                    internal_notes:        est.internalNotes,
                    internal_approved_at:  est.internalApprovedAt.map { isoFull.string(from: $0) },
                    loss_reason:           est.lossReason?.rawValue,
                    competitor_name:       est.competitorName,
                    win_loss_notes:        est.winLossNotes,
                    awarded_value:         est.awardedValue.map        { toDouble($0) },
                    line_items_json:       jsonString(est.lineItems),
                    contingency_percent:   toDouble(est.contingencyPercent),
                    overhead_percent:      toDouble(est.overheadPercent),
                    profit_percent:        toDouble(est.profitPercent),
                    notes:                 est.notes,
                    last_modified_by:      est.lastModifiedBy.isEmpty ? nil : est.lastModifiedBy,
                    created_at:            isoFull.string(from: est.createdAt),
                    updated_at:            isoFull.string(from: est.updatedAt),
                    origin_type:           est.originType.rawValue,
                    opportunity_id:        est.opportunityID?.uuidString,
                    terms_default_applied: est.termsDefaultApplied,
                    is_sample_data:           est.isSampleData,
                    sample_data_batch_id:     est.sampleDataBatchID?.uuidString,
                    sample_data_seed_version: est.sampleDataSeedVersion,
                    sample_data_created_at:   est.sampleDataCreatedAt.map { isoFull.string(from: $0) },
                    sample_data_created_by:   est.sampleDataCreatedBy?.uuidString
                )
                try await supabase.from(SupabaseTable.estimates).upsert(row).execute()
                if let i = store.estimates.firstIndex(where: { $0.id == est.id }) {
                    store.estimates[i].syncStatus = .synced
                }
            } catch {
                // 2026-04 audit: this catch was silent, which is why
                // "estimates not syncing" was hard to diagnose. Log
                // the error + estimate ID so the next time it happens
                // we can see exactly which row tripped which RLS /
                // CHECK constraint.
                print("⚠️ pushPendingEstimates failed for \(est.id): \(error)")
                CrashReporter.capture(error: error,
                                      context: [
                                        "operation":   "pushPendingEstimates",
                                        "estimate_id": est.id.uuidString
                                      ])
                if let i = store.estimates.firstIndex(where: { $0.id == est.id }) {
                    store.estimates[i].syncStatus = .failed
                }
            }
        }
        store.objectWillChange.send()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Quotes — Pull & Push
    // ─────────────────────────────────────────────────────────────────────────

    func pullQuotes(role: UserRole) async {
        guard !role.isFieldRole && !role.isExternal else { return }
        // BUG FIX: guard on companyID so we only pull this tenant's quotes
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, job_number: String
                let estimate_id: String?        // nullable — guard handles nil rows
                let client_id: String?
                let revision: Int?
                let client_name: String
                let site_address: String?
                let prepared_by: String
                let scope_summary, inclusions, exclusions, assumptions: String?
                let subtotal: Double?
                let discount_percent: Double?
                let contingency_percent: Double?
                let tax_rate: Double?
                let line_items_json: String?
                let payment_terms: String?
                let validity_days: Int?
                let status: String
                let approved_by, assigned_pm_name: String?
                let project_id, assigned_pm_id: String?
                let opportunity_id: String?
                /// SR-1 follow-up: labor pre-plan crew preference.
                /// Optional FK to crews(id). Nullable on legacy rows.
                let preferred_crew_id: String?
                /// SR-1.4: structured labor requirements (JSONB).
                /// Optional on legacy rows; defaults to empty plan.
                let labor_plan: LaborRequirement?
                let quote_date, expiry_date, created_at, updated_at: String?
                let approved_at, sent_at, accepted_at: String?
                let last_modified_by: String?
                let company_id: String?
                // Phase 4 audit fix: loss-tracking columns added by
                // the `quotes_loss_tracking` migration. Older rows
                // return null and round-trip to nil safely.
                let loss_reason:     String?
                let competitor_name: String?
                let win_loss_notes:  String?
                let declined_at:     String?
                /// 2026-04 re-audit fix: ISO 4217 currency. NOT NULL
                /// in DB with default 'USD' — older rows decode to "USD".
                let currency:        String?
                // Slice B: Terms & Conditions defaults-applied ledger
                let terms_default_applied: Bool?
                // Sample-data tracking
                let is_sample_data: Bool?
                let sample_data_batch_id: String?
                let sample_data_seed_version: String?
                let sample_data_created_at: String?
                let sample_data_created_by: String?
            }
            let rows: [Row] = try await supabase
                .from(SupabaseTable.quotes)
                .select()
                .eq("company_id", value: companyID.uuidString)   // FIX: tenant isolation
                .eq("is_deleted", value: false)
                .order("quote_date", ascending: false)
                .execute()
                .value

            // Include .failed so push-rejected quotes survive across pulls and
            // can be retried instead of silently disappearing.
            var current = store.quotes.filter {
                $0.syncStatus == .local || $0.syncStatus == .pending || $0.syncStatus == .failed
            }
            for row in rows {
                // estimate_id and client_id are nullable in DB; skip rows where they're absent
                guard let id        = UUID(uuidString: row.id),
                      let estimateID = row.estimate_id.flatMap({ UUID(uuidString: $0) }),
                      let clientID   = row.client_id.flatMap({ UUID(uuidString: $0) }) else { continue }
                var q = Quote(
                    jobNumber:   row.job_number,
                    estimateID:  estimateID,
                    clientID:    clientID,
                    clientName:  row.client_name,
                    preparedBy:  row.prepared_by
                )
                q.id               = id
                q.companyID        = row.company_id.flatMap(UUID.init(uuidString:))
                q.revision         = row.revision ?? 1
                q.siteAddress      = row.site_address
                q.scopeSummary     = row.scope_summary ?? ""
                q.inclusions       = row.inclusions ?? ""
                q.exclusions       = row.exclusions ?? ""
                q.assumptions      = row.assumptions ?? ""
                q.subtotal           = fromDouble(row.subtotal)
                q.discountPercent    = fromDouble(row.discount_percent)
                q.contingencyPercent = fromDouble(row.contingency_percent)
                q.taxRate            = fromDouble(row.tax_rate)
                q.lineItems          = decodeJSON(row.line_items_json, as: [CostCodeItem].self) ?? []
                q.paymentTerms       = row.payment_terms ?? ""
                q.validityDays     = row.validity_days ?? 30
                q.status           = QuoteStatus(rawValue: row.status) ?? .draft
                q.approvedBy       = row.approved_by
                q.assignedPMName   = row.assigned_pm_name
                q.opportunityID    = row.opportunity_id.flatMap { UUID(uuidString: $0) }
                q.projectID        = row.project_id.flatMap    { UUID(uuidString: $0) }
                q.assignedPMID     = row.assigned_pm_id.flatMap { UUID(uuidString: $0) }
                q.preferredCrewID  = row.preferred_crew_id.flatMap { UUID(uuidString: $0) }
                // SR-1.4: hydrate the structured labor requirements.
                q.laborPlan        = row.labor_plan ?? LaborRequirement()
                q.quoteDate        = parseDate(row.quote_date) ?? Date()
                q.expiryDate       = parseDate(row.expiry_date) ?? Date()
                q.createdAt        = parseDate(row.created_at) ?? Date()
                q.updatedAt        = parseDate(row.updated_at) ?? q.createdAt
                q.lastModifiedBy   = row.last_modified_by ?? ""
                q.lastModifiedAt   = q.updatedAt
                q.approvedAt       = parseDate(row.approved_at)
                q.sentAt           = parseDate(row.sent_at)
                q.acceptedAt       = parseDate(row.accepted_at)
                q.lossReason       = row.loss_reason.flatMap { LossReason(rawValue: $0) }
                q.competitorName   = row.competitor_name
                q.winLossNotes     = row.win_loss_notes
                q.declinedAt       = parseDate(row.declined_at)
                q.currency         = row.currency ?? "USD"
                q.termsDefaultApplied = row.terms_default_applied ?? false
                q.syncStatus       = .synced
                q.isSampleData          = row.is_sample_data ?? false
                q.sampleDataBatchID     = row.sample_data_batch_id.flatMap(UUID.init(uuidString:))
                q.sampleDataSeedVersion = row.sample_data_seed_version
                q.sampleDataCreatedAt   = parseDate(row.sample_data_created_at)
                q.sampleDataCreatedBy   = row.sample_data_created_by.flatMap(UUID.init(uuidString:))
                current.removeAll { $0.id == q.id }
                current.append(q)
            }
            await MainActor.run {
                store.quotes = current
                store.objectWillChange.send()
            }

            // PHASE-1 VERIFIED: magic-link completion + drift recovery.
            // Extracted to reconcileQuoteOutcomeDrift() in Step 4 so the
            // dev menu (RoleProbeView) can run it on demand for QA without
            // duplicating the logic. Runs on every main pull cycle here.
            await reconcileQuoteOutcomeDrift()

            // Signed-PDF generation: for every quote currently in
            // .accepted status, ensure a signed PDF + Acceptance
            // Certificate page exists in the local documents store
            // and has been emailed to the customer + company. The
            // generator is idempotent (UserDefaults ledger keyed on
            // quote.id), so this loop is safe to run on every pull —
            // already-processed quotes are filtered before any
            // network calls.
            let acceptedQuotes = await MainActor.run {
                store.quotes.filter { $0.status == .accepted && !$0.isDeleted }
            }
            for q in acceptedQuotes {
                await SignedQuotePDFGenerator.shared.ensureSignedPDF(for: q, store: store)
            }
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
            print("⚠️ pullQuotes failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "pullQuotes"])
            syncError = "Quotes: \(error.localizedDescription)"
        }
    }

    func pushPendingQuotes() async {
        // BUG FIX: company_id is required by the server; bail out if we can't supply it
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.quotes.filter { $0.syncStatus == .pending || $0.syncStatus == .local }
        guard !pending.isEmpty else { return }
        for q in pending {
            do {
                struct Row: Encodable {
                    let id, job_number, estimate_id, client_id, client_name: String
                    let company_id: String           // FIX: was missing — caused every upsert to fail
                    let revision: Int
                    let site_address, scope_summary, inclusions, exclusions, assumptions: String?
                    let prepared_by: String
                    let subtotal, discount_percent, contingency_percent, tax_rate: Double
                    let line_items_json: String
                    let payment_terms: String
                    let validity_days: Int
                    let status: String
                    let approved_by, assigned_pm_name: String?
                    let opportunity_id: String?      // FIX: persist opportunity linkage
                    let project_id, assigned_pm_id: String?
                    /// SR-1 follow-up: labor pre-plan crew preference.
                    let preferred_crew_id: String?
                    /// SR-1.4: structured labor requirements (JSONB).
                    let labor_plan: LaborRequirement
                    let quote_date, expiry_date, created_at, updated_at: String
                    let approved_at, sent_at, accepted_at: String?
                    let last_modified_by: String?
                    let is_deleted: Bool
                    let deleted_at: String?
                    let deleted_by: String?
                    // Phase 4 audit fix: loss tracking persisted server-side.
                    let loss_reason:     String?
                    let competitor_name: String?
                    let win_loss_notes:  String?
                    let declined_at:     String?
                    /// 2026-04 re-audit fix.
                    let currency:        String
                    // Slice B: terms defaults-applied ledger
                    let terms_default_applied: Bool
                    // Sample-data tracking
                    let is_sample_data: Bool
                    let sample_data_batch_id: String?
                    let sample_data_seed_version: String?
                    let sample_data_created_at: String?
                    let sample_data_created_by: String?
                }
                let row = Row(
                    id:                  q.id.uuidString,
                    job_number:          q.jobNumber,
                    estimate_id:         q.estimateID.uuidString,
                    client_id:           q.clientID.uuidString,
                    client_name:         q.clientName,
                    company_id:          companyID.uuidString,
                    revision:            q.revision,
                    site_address:        q.siteAddress,
                    scope_summary:       q.scopeSummary.isEmpty ? nil : q.scopeSummary,
                    inclusions:          q.inclusions.isEmpty ? nil : q.inclusions,
                    exclusions:          q.exclusions.isEmpty ? nil : q.exclusions,
                    assumptions:         q.assumptions.isEmpty ? nil : q.assumptions,
                    prepared_by:         q.preparedBy,
                    subtotal:            NSDecimalNumber(decimal: q.lineItemsSubtotal).doubleValue,
                    discount_percent:    NSDecimalNumber(decimal: q.discountPercent).doubleValue,
                    contingency_percent: NSDecimalNumber(decimal: q.contingencyPercent).doubleValue,
                    tax_rate:            NSDecimalNumber(decimal: q.taxRate).doubleValue,
                    line_items_json:     jsonString(q.lineItems),
                    payment_terms:       q.paymentTerms,
                    validity_days:       q.validityDays,
                    status:              q.status.rawValue,
                    approved_by:         q.approvedBy,
                    assigned_pm_name:    q.assignedPMName,
                    opportunity_id:      q.opportunityID?.uuidString,
                    project_id:          q.projectID?.uuidString,
                    assigned_pm_id:      q.assignedPMID?.uuidString,
                    preferred_crew_id:   q.preferredCrewID?.uuidString,
                    labor_plan:          q.laborPlan,
                    quote_date:          isoDateFmt.string(from: q.quoteDate),
                    expiry_date:         isoDateFmt.string(from: q.expiryDate),
                    created_at:          isoFull.string(from: q.createdAt),
                    updated_at:          isoFull.string(from: q.updatedAt),
                    approved_at:         q.approvedAt.map { isoFull.string(from: $0) },
                    sent_at:             q.sentAt.map     { isoFull.string(from: $0) },
                    accepted_at:         q.acceptedAt.map { isoFull.string(from: $0) },
                    last_modified_by:    q.lastModifiedBy.isEmpty ? nil : q.lastModifiedBy,
                    is_deleted:          q.isDeleted,
                    deleted_at:          q.deletedAt.map { isoFull.string(from: $0) },
                    deleted_by:          q.deletedBy,
                    loss_reason:         q.lossReason?.rawValue,
                    competitor_name:     q.competitorName,
                    win_loss_notes:      q.winLossNotes,
                    declined_at:         q.declinedAt.map { isoFull.string(from: $0) },
                    currency:            q.currency.isEmpty ? "USD" : q.currency,
                    terms_default_applied: q.termsDefaultApplied,
                    is_sample_data:           q.isSampleData,
                    sample_data_batch_id:     q.sampleDataBatchID?.uuidString,
                    sample_data_seed_version: q.sampleDataSeedVersion,
                    sample_data_created_at:   q.sampleDataCreatedAt.map { isoFull.string(from: $0) },
                    sample_data_created_by:   q.sampleDataCreatedBy?.uuidString
                )
                try await supabase.from(SupabaseTable.quotes).upsert(row).execute()
                store.markQuoteSynced(id: q.id, status: .synced)
                store.quotes.removeAll { $0.isDeleted && $0.syncStatus == .synced }
            } catch {
                store.markQuoteSynced(id: q.id, status: .failed)
            }
        }
    }

    // MARK: - Phase 1 Step 4: Quote Outcome Drift Reconciliation
    //
    // Two correction passes that close the magic-link customer-acceptance
    // loop. Both are idempotent — safe to run on every pull cycle AND
    // on-demand from the dev menu's drift-sweep button.
    //
    // 1. **Magic-link orphan recovery.** When a customer accepts via
    //    `accept_quote_via_token`, the server flips quotes.status to
    //    `.accepted` but the iOS-side project + CRM outcome wiring
    //    never fires (the rep wasn't on-device when it happened).
    //    We find any `.accepted` quote with no projectID and re-run
    //    `resolveOpportunityOutcome(.won)` on its linked opp to create
    //    the project + activity log + handoff checklist.
    //
    // 2. **Status drift correction.** Any quote whose linked opp is
    //    already `.won` but whose own status is still `.draft` or
    //    `.approved` is in an inconsistent state. We force it to
    //    `.accepted` so reporting + UI agree with reality. Excludes
    //    `.declined` (legit terminal) and `.sent` (could still be
    //    in flight even when the opp closed via another path).
    //
    // Returns a small summary so the dev-menu surface can show the
    // technician how many rows were corrected.
    @MainActor
    @discardableResult
    func reconcileQuoteOutcomeDrift() async -> QuoteDriftSweepResult {
        var orphansCreated     = 0
        var orphansSkipped     = 0
        var driftedFlipped     = 0

        // Pass 1: magic-link orphans.
        let orphans = store.quotes.filter {
            $0.status == .accepted
            && $0.projectID == nil
            && !$0.isDeleted
        }
        for orphan in orphans {
            if let opp = store.crmOpportunities.first(where: {
                !$0.isDeleted &&
                ($0.quoteID == orphan.id || $0.estimateID == orphan.estimateID)
            }) {
                print("🔗 magic-link completion → creating project for quote \(orphan.id)")
                store.resolveOpportunityOutcome(
                    opportunityID: opp.id,
                    outcome:       .won,
                    source:        .commercialQuote,
                    quoteID:       orphan.id,
                    estimateID:    orphan.estimateID,
                    projectID:     nil   // let the bridge auto-create
                )
                orphansCreated += 1
            } else {
                print("⚠️ magic-link orphan quote \(orphan.id) has no linked opportunity — skipping auto-project")
                orphansSkipped += 1
            }
        }

        // Pass 2: status-drift correction.
        let driftedQuotes = store.quotes.filter { q in
            !q.isDeleted
            && (q.status == .draft || q.status == .approved)
            && store.crmOpportunities.contains(where: {
                !$0.isDeleted
                && $0.stage == .won
                && ($0.quoteID == q.id || $0.estimateID == q.estimateID)
            })
        }
        for var q in driftedQuotes {
            print("🔧 status-drift fix → forcing quote \(q.id) from \(q.status.rawValue) to .accepted (linked opp is Won)")
            q.status     = .accepted
            q.acceptedAt = q.acceptedAt ?? Date()
            q.syncStatus = .pending
            if let idx = store.quotes.firstIndex(where: { $0.id == q.id }) {
                store.quotes[idx] = q
                driftedFlipped += 1
            }
        }
        if driftedFlipped > 0 {
            Task { await SyncEngine.shared.pushPendingQuotes() }
        }

        return QuoteDriftSweepResult(
            orphansRecovered: orphansCreated,
            orphansSkipped:   orphansSkipped,
            driftedFlipped:   driftedFlipped
        )
    }
}

/// Phase 1 Step 4 — summary returned by `reconcileQuoteOutcomeDrift`.
/// Surfaced in the dev-menu drift-sweep button so QA can confirm the
/// magic-link path closed the loop without scraping logs.
struct QuoteDriftSweepResult: Equatable {
    /// Magic-link orphan quotes that had a linked opportunity and were
    /// recovered into projects via `resolveOpportunityOutcome`.
    let orphansRecovered: Int
    /// Magic-link orphan quotes with NO linked opportunity. These are
    /// genuinely missing CRM linkage and need manual repair.
    let orphansSkipped: Int
    /// Quotes whose status was forced to `.accepted` because their
    /// linked opp was already `.won`.
    let driftedFlipped: Int

    var totalCorrections: Int { orphansRecovered + driftedFlipped }
}
