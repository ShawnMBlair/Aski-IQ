// SyncEngineExpenses.swift
// Phase 9 / Expenses v1.1 — push/pull functions for the two expense
// tables. Mirrors the SyncEngineInventory pattern (Phase 8) so the
// new module slots into the AskiSyncClient seam from Phase 5 / Wave 2.
//
// REQUIRES: EXP1 + EXP2 migrations applied to the target Supabase
// project. Without them every upsert returns 42703 ("column does not
// exist") which the per-row recordSyncError pattern surfaces on the
// Failed Syncs screen. EXP1 + EXP2 apply order is documented in
// `migrations/phase9_expenses/README.md`.
//
// File-data handling: ExpenseAttachment carries `fileData` and
// `thumbnailData` as `Data?`. Swift's default Data codable round-trips
// via base64 strings on the wire, which PostgREST accepts and decodes
// into bytea. If receipt payloads grow past PostgREST's practical
// 10 MB-per-request ceiling we migrate to Supabase Storage (EXP4 in
// the deferred list).

import Foundation
import Combine
import Supabase

// Local ISO8601 formatter — `isoFull` on SyncEngine is private.
// Mirroring its exact configuration so timestamps round-trip
// identically to the rest of the app.
private let _expIsoFull: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let _expDateOnly: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone   = TimeZone(secondsFromGMT: 0)
    return f
}()

extension SyncEngine {

    // ─────────────────────────────────────────────────────────────────
    // MARK: Expenses
    // ─────────────────────────────────────────────────────────────────

    func pullExpenses() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, company_id: String
                let external_id: String?
                let expense_number: String
                let vendor, currency, memo, category, payment_method: String
                let expense_date: String
                let amount: Decimal
                let destination: String
                let project_id, material_request_id: String?
                let company_destination_label: String
                let is_reimbursable: Bool
                let reimbursement_paid_at: String?
                let reimbursement_paid_by: String?
                let reimbursement_payment_method: String?
                let approval_state: String
                let approved_by, rejected_by: String?
                let approved_at, rejected_at: String?
                let rejection_reason: String
                let created_by, submitted_by, expense_owner_employee_id: String?
                let submitted_on_behalf_of: Bool
                let possible_duplicate_of: String?
                let created_at, updated_at: String?
                let last_modified_by: String?
                let last_modified_at: String?
                let sync_status: String?
                let is_deleted: Bool?
                let deleted_at: String?
                let deleted_by: String?
                let is_sample_data: Bool?
                let sample_data_batch_id, sample_data_seed_version: String?
                let sample_data_created_at, sample_data_created_by: String?
            }
            let rows: [Row] = try await client.select(
                Row.self,
                from: SupabaseTable.expenses,
                filters: [
                    .eq("company_id", companyID.uuidString),
                    .eq("is_deleted", false)
                ],
                orderBy: "expense_date",
                ascending: false
            )

            let parsed: [Expense] = rows.compactMap { row in
                guard let id = UUID(uuidString: row.id),
                      let cid = UUID(uuidString: row.company_id) else { return nil }
                var e = Expense()
                e.id                          = id
                e.externalID                  = row.external_id
                e.companyID                   = cid
                e.expenseNumber               = row.expense_number
                e.vendor                      = row.vendor
                e.expenseDate                 = _expDateOnly.date(from: row.expense_date) ?? Date()
                e.amount                      = row.amount
                e.currency                    = row.currency
                e.memo                        = row.memo
                e.category                    = ExpenseCategory(rawValue: row.category) ?? .other
                e.paymentMethod               = ExpensePaymentMethod(rawValue: row.payment_method) ?? .companyCard
                e.destination                 = ExpenseDestination(rawValue: row.destination) ?? .company
                e.projectID                   = row.project_id.flatMap(UUID.init(uuidString:))
                e.materialRequestID           = row.material_request_id.flatMap(UUID.init(uuidString:))
                e.companyDestinationLabel     = row.company_destination_label
                e.isReimbursable              = row.is_reimbursable
                e.reimbursementPaidAt         = row.reimbursement_paid_at.flatMap(_expIsoFull.date(from:))
                e.reimbursementPaidBy         = row.reimbursement_paid_by.flatMap(UUID.init(uuidString:))
                e.reimbursementPaymentMethod  = row.reimbursement_payment_method.flatMap(ExpensePaymentMethod.init(rawValue:))
                e.approvalState               = ExpenseApprovalState(rawValue: row.approval_state) ?? .draft
                e.approvedBy                  = row.approved_by.flatMap(UUID.init(uuidString:))
                e.rejectedBy                  = row.rejected_by.flatMap(UUID.init(uuidString:))
                e.approvedAt                  = row.approved_at.flatMap(_expIsoFull.date(from:))
                e.rejectedAt                  = row.rejected_at.flatMap(_expIsoFull.date(from:))
                e.rejectionReason             = row.rejection_reason
                e.createdBy                   = row.created_by.flatMap(UUID.init(uuidString:))
                e.submittedBy                 = row.submitted_by.flatMap(UUID.init(uuidString:))
                e.expenseOwnerEmployeeID      = row.expense_owner_employee_id.flatMap(UUID.init(uuidString:))
                e.submittedOnBehalfOf         = row.submitted_on_behalf_of
                e.possibleDuplicateOf         = row.possible_duplicate_of.flatMap(UUID.init(uuidString:))
                e.createdAt                   = row.created_at.flatMap(_expIsoFull.date(from:)) ?? Date()
                e.updatedAt                   = row.updated_at.flatMap(_expIsoFull.date(from:)) ?? Date()
                e.lastModifiedBy              = row.last_modified_by ?? ""
                e.lastModifiedAt              = row.last_modified_at.flatMap(_expIsoFull.date(from:)) ?? Date()
                e.syncStatus                  = .synced
                e.isDeleted                   = row.is_deleted ?? false
                e.deletedAt                   = row.deleted_at.flatMap(_expIsoFull.date(from:))
                e.deletedBy                   = row.deleted_by
                e.isSampleData                = row.is_sample_data ?? false
                e.sampleDataBatchID           = row.sample_data_batch_id.flatMap(UUID.init(uuidString:))
                e.sampleDataSeedVersion       = row.sample_data_seed_version
                e.sampleDataCreatedAt         = row.sample_data_created_at.flatMap(_expIsoFull.date(from:))
                e.sampleDataCreatedBy         = row.sample_data_created_by.flatMap(UUID.init(uuidString:))
                return e
            }

            await MainActor.run {
                store.expenses = parsed
                store.objectWillChange.send()
            }
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    func pushPendingExpenses() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.expenses.filter { $0.syncStatus == .pending || $0.syncStatus == .local }
        for e in pending {
            do {
                struct Row: Encodable {
                    let id, company_id: String
                    let external_id: String?
                    let expense_number, vendor, currency, memo, category, payment_method: String
                    let expense_date: String
                    let amount: Decimal
                    let destination: String
                    let project_id, material_request_id: String?
                    let company_destination_label: String
                    let is_reimbursable: Bool
                    let reimbursement_paid_at: String?
                    let reimbursement_paid_by: String?
                    let reimbursement_payment_method: String?
                    let approval_state: String
                    let approved_by, rejected_by: String?
                    let approved_at, rejected_at: String?
                    let rejection_reason: String
                    let created_by, submitted_by, expense_owner_employee_id: String?
                    let submitted_on_behalf_of: Bool
                    let possible_duplicate_of: String?
                    let created_at, updated_at, last_modified_at: String
                    let last_modified_by: String
                    let is_deleted: Bool
                    let deleted_at, deleted_by: String?
                    let is_sample_data: Bool
                    let sample_data_batch_id, sample_data_seed_version: String?
                    let sample_data_created_at, sample_data_created_by: String?
                }
                let row = Row(
                    id:                          e.id.uuidString,
                    company_id:                  (e.companyID ?? companyID).uuidString,
                    external_id:                 e.externalID,
                    expense_number:              e.expenseNumber,
                    vendor:                      e.vendor,
                    currency:                    e.currency,
                    memo:                        e.memo,
                    category:                    e.category.rawValue,
                    payment_method:              e.paymentMethod.rawValue,
                    expense_date:                _expDateOnly.string(from: e.expenseDate),
                    amount:                      e.amount,
                    destination:                 e.destination.rawValue,
                    project_id:                  e.projectID?.uuidString,
                    material_request_id:         e.materialRequestID?.uuidString,
                    company_destination_label:   e.companyDestinationLabel,
                    is_reimbursable:             e.isReimbursable,
                    reimbursement_paid_at:       e.reimbursementPaidAt.map { _expIsoFull.string(from: $0) },
                    reimbursement_paid_by:       e.reimbursementPaidBy?.uuidString,
                    reimbursement_payment_method: e.reimbursementPaymentMethod?.rawValue,
                    approval_state:              e.approvalState.rawValue,
                    approved_by:                 e.approvedBy?.uuidString,
                    rejected_by:                 e.rejectedBy?.uuidString,
                    approved_at:                 e.approvedAt.map { _expIsoFull.string(from: $0) },
                    rejected_at:                 e.rejectedAt.map { _expIsoFull.string(from: $0) },
                    rejection_reason:            e.rejectionReason,
                    created_by:                  e.createdBy?.uuidString,
                    submitted_by:                e.submittedBy?.uuidString,
                    expense_owner_employee_id:   e.expenseOwnerEmployeeID?.uuidString,
                    submitted_on_behalf_of:      e.submittedOnBehalfOf,
                    possible_duplicate_of:       e.possibleDuplicateOf?.uuidString,
                    created_at:                  _expIsoFull.string(from: e.createdAt),
                    updated_at:                  _expIsoFull.string(from: e.updatedAt),
                    last_modified_at:            _expIsoFull.string(from: e.lastModifiedAt),
                    last_modified_by:            e.lastModifiedBy,
                    is_deleted:                  e.isDeleted,
                    deleted_at:                  e.deletedAt.map { _expIsoFull.string(from: $0) },
                    deleted_by:                  e.deletedBy,
                    is_sample_data:              e.isSampleData,
                    sample_data_batch_id:        e.sampleDataBatchID?.uuidString,
                    sample_data_seed_version:    e.sampleDataSeedVersion,
                    sample_data_created_at:      e.sampleDataCreatedAt.map { _expIsoFull.string(from: $0) },
                    sample_data_created_by:      e.sampleDataCreatedBy?.uuidString
                )
                try await client.upsert(row, into: SupabaseTable.expenses)
                if let i = store.expenses.firstIndex(where: { $0.id == e.id }) {
                    store.expenses[i].syncStatus = .synced
                }
                store.expenses.removeAll { $0.isDeleted && $0.syncStatus == .synced }
                await MainActor.run { store.clearSyncError(id: e.id) }
            } catch {
                if let i = store.expenses.firstIndex(where: { $0.id == e.id }) {
                    store.expenses[i].syncStatus = .failed
                }
                await MainActor.run { store.recordSyncError(id: e.id, error: error) }
                CrashReporter.capture(error: error, context: [
                    "operation":      "\(#function)",
                    "expense_id":     e.id.uuidString,
                    "expense_number": e.expenseNumber
                ])
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: Expense Attachments
    // ─────────────────────────────────────────────────────────────────

    func pullExpenseAttachments() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, company_id, expense_id: String
                let external_id: String?
                let file_name, file_type, mime_type: String
                let file_size_bytes: Int
                /// bytea on the server side. PostgREST encodes as
                /// base64 "\x..." which Swift's Data Codable decodes
                /// directly. Optional in case rows exist without file
                /// data (rare but harmless).
                let file_data: Data?
                let thumbnail_data: Data?
                let source: String
                let is_primary_receipt: Bool
                let created_at, updated_at, last_modified_at: String?
                let last_modified_by: String?
                let sync_status: String?
                let is_deleted: Bool?
                let deleted_at, deleted_by: String?
            }
            let rows: [Row] = try await client.select(
                Row.self,
                from: SupabaseTable.expenseAttachments,
                filters: [
                    .eq("company_id", companyID.uuidString),
                    .eq("is_deleted", false)
                ],
                orderBy: "created_at",
                ascending: false
            )

            let parsed: [ExpenseAttachment] = rows.compactMap { row in
                guard let id   = UUID(uuidString: row.id),
                      let cid  = UUID(uuidString: row.company_id),
                      let eid  = UUID(uuidString: row.expense_id) else { return nil }
                var a = ExpenseAttachment(expenseID: eid)
                a.id                = id
                a.externalID        = row.external_id
                a.companyID         = cid
                a.fileName          = row.file_name
                a.fileType          = ExpenseAttachmentFileType(rawValue: row.file_type) ?? .other
                a.mimeType          = row.mime_type
                a.fileSizeBytes     = row.file_size_bytes
                a.fileData          = row.file_data
                a.thumbnailData     = row.thumbnail_data
                a.source            = ExpenseAttachmentSource(rawValue: row.source) ?? .filePicker
                a.isPrimaryReceipt  = row.is_primary_receipt
                a.createdAt         = row.created_at.flatMap(_expIsoFull.date(from:)) ?? Date()
                a.updatedAt         = row.updated_at.flatMap(_expIsoFull.date(from:)) ?? Date()
                a.lastModifiedAt    = row.last_modified_at.flatMap(_expIsoFull.date(from:)) ?? Date()
                a.lastModifiedBy    = row.last_modified_by ?? ""
                a.syncStatus        = .synced
                a.isDeleted         = row.is_deleted ?? false
                a.deletedAt         = row.deleted_at.flatMap(_expIsoFull.date(from:))
                a.deletedBy         = row.deleted_by
                return a
            }

            await MainActor.run {
                store.expenseAttachments = parsed
                store.objectWillChange.send()
            }
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    func pushPendingExpenseAttachments() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.expenseAttachments.filter { $0.syncStatus == .pending || $0.syncStatus == .local }
        for a in pending {
            do {
                struct Row: Encodable {
                    let id, company_id, expense_id: String
                    let external_id: String?
                    let file_name, file_type, mime_type: String
                    let file_size_bytes: Int
                    let file_data, thumbnail_data: Data?
                    let source: String
                    let is_primary_receipt: Bool
                    let created_at, updated_at, last_modified_at: String
                    let last_modified_by: String
                    let is_deleted: Bool
                    let deleted_at, deleted_by: String?
                }
                let row = Row(
                    id:                  a.id.uuidString,
                    company_id:          (a.companyID ?? companyID).uuidString,
                    expense_id:          a.expenseID.uuidString,
                    external_id:         a.externalID,
                    file_name:           a.fileName,
                    file_type:           a.fileType.rawValue,
                    mime_type:           a.mimeType,
                    file_size_bytes:     a.fileSizeBytes,
                    file_data:           a.fileData,
                    thumbnail_data:      a.thumbnailData,
                    source:              a.source.rawValue,
                    is_primary_receipt:  a.isPrimaryReceipt,
                    created_at:          _expIsoFull.string(from: a.createdAt),
                    updated_at:          _expIsoFull.string(from: a.updatedAt),
                    last_modified_at:    _expIsoFull.string(from: a.lastModifiedAt),
                    last_modified_by:    a.lastModifiedBy,
                    is_deleted:          a.isDeleted,
                    deleted_at:          a.deletedAt.map { _expIsoFull.string(from: $0) },
                    deleted_by:          a.deletedBy
                )
                try await client.upsert(row, into: SupabaseTable.expenseAttachments)
                if let i = store.expenseAttachments.firstIndex(where: { $0.id == a.id }) {
                    store.expenseAttachments[i].syncStatus = .synced
                }
                store.expenseAttachments.removeAll { $0.isDeleted && $0.syncStatus == .synced }
                await MainActor.run { store.clearSyncError(id: a.id) }
            } catch {
                if let i = store.expenseAttachments.firstIndex(where: { $0.id == a.id }) {
                    store.expenseAttachments[i].syncStatus = .failed
                }
                await MainActor.run { store.recordSyncError(id: a.id, error: error) }
                CrashReporter.capture(error: error, context: [
                    "operation":     "\(#function)",
                    "attachment_id": a.id.uuidString,
                    "expense_id":    a.expenseID.uuidString,
                    "file_name":     a.fileName
                ])
            }
        }
    }
}
