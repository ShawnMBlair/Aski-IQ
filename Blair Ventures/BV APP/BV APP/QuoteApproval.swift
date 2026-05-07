// QuoteApproval.swift
// Aski IQ — Entity-First CRM, Slice 5: Approval Thresholds (Four-Eyes)
//
// Spec from the master prompt (Phase 12):
//   < $10K       → Sales (any role can send, no approval)
//   $10K – $50K  → Manager Approval
//   > $50K       → Admin Approval
//
// A quote can have multiple approval cycles in its lifetime — rejected
// → modified → re-requested. Each cycle is a row in quote_approvals.
// `latestApproval(for:)` returns the most recent regardless of status,
// so the UI can render "pending Manager approval" or "rejected — see
// notes" or "approved by Sarah on Mar 4".
//
// THE GATE
// Slice 4's `CommercialWorkflowService.recordQuoteSent(...)` was the
// chokepoint for "is this transition allowed?". Slice 5 wraps it with
// "is this transition allowed AND is the dollar figure approved?".
// The threshold check returns .approvalRequired when the gate is hit;
// the rep sees "Request Approval" instead of "Send".

import Foundation
import Combine
import SwiftUI
import Supabase
import PostgREST

// MARK: - Threshold tier

/// Which approval level a given quote total triggers. The thresholds
/// are configurable per-company via AppSettings (future) but seeded
/// today from the master spec values.
enum ApprovalThreshold {
    /// Total ≤ this → no approval required.
    /// Anything above this and ≤ managerCeiling → manager approval.
    /// Above managerCeiling → admin approval.
    static let salesCeilingUSD:   Decimal = 10_000
    static let managerCeilingUSD: Decimal = 50_000

    enum Tier: String, Codable {
        /// No approval needed. (Sales role can self-send.)
        case none
        /// Manager (or executive) approval needed.
        case manager
        /// Executive (admin) approval needed. Manager can't approve.
        case admin

        var displayName: String {
            switch self {
            case .none:    return "No approval needed"
            case .manager: return "Manager approval required"
            case .admin:   return "Admin approval required"
            }
        }
    }

    /// Returns the tier for a given quote total. Currency is preserved
    /// for the audit row but the threshold comparison treats all
    /// currencies as USD-equivalent for now (future: per-currency
    /// thresholds in CompanySettings).
    static func tier(forTotal total: Decimal) -> Tier {
        if total <= salesCeilingUSD   { return .none }
        if total <= managerCeilingUSD { return .manager }
        return .admin
    }

    /// True when the supplied role can satisfy the supplied tier.
    /// Used to (a) gate the "Approve" button visibility and (b) check
    /// authorization server-side before flipping the approval row.
    static func canApprove(tier: Tier, role: UserRole) -> Bool {
        switch tier {
        case .none:    return true
        case .manager: return role == .manager || role == .executive
        case .admin:   return role == .executive
        }
    }
}

// MARK: - Status

enum QuoteApprovalStatus: String, Codable, CaseIterable, Identifiable {
    case pending, approved, rejected, cancelled
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pending:   return "Pending"
        case .approved:  return "Approved"
        case .rejected:  return "Rejected"
        case .cancelled: return "Cancelled"
        }
    }

    var color: Color {
        switch self {
        case .pending:   return .orange
        case .approved:  return .green
        case .rejected:  return .red
        case .cancelled: return .gray
        }
    }

    var icon: String {
        switch self {
        case .pending:   return "clock.fill"
        case .approved:  return "checkmark.seal.fill"
        case .rejected:  return "xmark.seal.fill"
        case .cancelled: return "minus.circle.fill"
        }
    }
}

// MARK: - Model

struct QuoteApproval: Identifiable, Codable, Equatable {
    var id:            UUID = UUID()
    var quoteID:       UUID
    var companyID:     UUID

    // Snapshot at request time
    var quoteTotal:    Decimal
    var thresholdTier: ApprovalThreshold.Tier
    var currency:      String = "USD"

    // Request
    var requestedBy:     UUID
    var requestedByName: String = ""
    var requestedAt:     Date = Date()

    // Decision
    var status:         QuoteApprovalStatus = .pending
    var decidedBy:      UUID?
    var decidedByName:  String = ""
    var decidedAt:      Date?
    var decisionNotes:  String = ""

    var createdAt:  Date = Date()
    var updatedAt:  Date = Date()
    var syncStatus: SyncStatus = .local

    /// Display string for the dollar amount that triggered approval.
    var quoteTotalString: String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency.isEmpty ? "USD" : currency
        f.maximumFractionDigits = 2
        return f.string(from: NSDecimalNumber(decimal: quoteTotal)) ?? "\(quoteTotal)"
    }
}

// MARK: - AppStore storage

extension AppStore {

    /// All approvals for the current tenant, kept in a UserDefaults-
    /// backed cache. Sync replaces wholesale on each pull.
    var quoteApprovals: [QuoteApproval] {
        if let cached = AppStore._approvalsCache { return cached }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = UserDefaults.standard.data(forKey: "ak_quote_approvals"),
              let arr  = try? dec.decode([QuoteApproval].self, from: data) else {
            return []
        }
        AppStore._approvalsCache = arr
        return arr
    }

    fileprivate func writeApprovals(_ arr: [QuoteApproval]) {
        AppStore._approvalsCache = arr
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(arr) {
            UserDefaults.standard.set(data, forKey: "ak_quote_approvals")
        }
    }

    private static var _approvalsCache: [QuoteApproval]? = nil

    /// All approval cycles for a quote, newest first.
    func approvals(for quoteID: UUID) -> [QuoteApproval] {
        quoteApprovals
            .filter { $0.quoteID == quoteID }
            .sorted { $0.requestedAt > $1.requestedAt }
    }

    /// Most recent approval row for a quote (any status). nil = never
    /// requested.
    func latestApproval(for quoteID: UUID) -> QuoteApproval? {
        approvals(for: quoteID).first
    }

    /// All currently-pending approvals across the tenant — sorted
    /// requested-at ascending so the queue shows oldest at the top.
    /// Used by the Pending Approvals list view.
    var pendingApprovals: [QuoteApproval] {
        quoteApprovals
            .filter { $0.status == .pending }
            .sorted { $0.requestedAt < $1.requestedAt }
    }

    /// Insert or update locally. Caller is responsible for hitting
    /// the sync push afterward (CommercialWorkflowService does this).
    func upsertApproval(_ approval: QuoteApproval) {
        var copy = approval
        copy.updatedAt = Date()
        if copy.syncStatus == .synced { copy.syncStatus = .pending }
        if copy.syncStatus == .local  { copy.syncStatus = .pending }

        var current = quoteApprovals
        if let i = current.firstIndex(where: { $0.id == copy.id }) {
            current[i] = copy
        } else {
            current.append(copy)
        }
        writeApprovals(current)
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPendingQuoteApprovals() }
    }
}

// MARK: - Sync engine

private func parseApprovalDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f1.date(from: s) { return d }
    let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
    return f2.date(from: s)
}

extension SyncEngine {

    func pullQuoteApprovals() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, quote_id, company_id: String
                let quote_total: Double
                let threshold_tier: String
                let currency: String?
                let requested_by: String
                let requested_by_name: String?
                let requested_at: String?
                let status: String
                let decided_by: String?
                let decided_by_name: String?
                let decided_at: String?
                let decision_notes: String?
                let created_at: String?
                let updated_at: String?
            }
            let rows: [Row] = try await supabase
                .from(SupabaseTable.quoteApprovals)
                .select()
                .eq("company_id", value: companyID.uuidString)
                .execute()
                .value

            let approvals: [QuoteApproval] = rows.compactMap { r in
                guard let id  = UUID(uuidString: r.id),
                      let qid = UUID(uuidString: r.quote_id),
                      let cid = UUID(uuidString: r.company_id),
                      let req = UUID(uuidString: r.requested_by) else { return nil }
                var a = QuoteApproval(
                    id: id, quoteID: qid, companyID: cid,
                    quoteTotal: Decimal(r.quote_total),
                    thresholdTier: ApprovalThreshold.Tier(rawValue: r.threshold_tier) ?? .manager,
                    currency: r.currency ?? "USD",
                    requestedBy: req,
                    requestedByName: r.requested_by_name ?? "",
                    requestedAt: parseApprovalDate(r.requested_at) ?? Date()
                )
                a.status         = QuoteApprovalStatus(rawValue: r.status) ?? .pending
                a.decidedBy      = r.decided_by.flatMap(UUID.init(uuidString:))
                a.decidedByName  = r.decided_by_name ?? ""
                a.decidedAt      = parseApprovalDate(r.decided_at)
                a.decisionNotes  = r.decision_notes ?? ""
                a.createdAt      = parseApprovalDate(r.created_at) ?? Date()
                a.updatedAt      = parseApprovalDate(r.updated_at) ?? Date()
                a.syncStatus     = .synced
                return a
            }

            // Merge: keep server rows + local-pending edits.
            await MainActor.run {
                let local = store.quoteApprovals.filter {
                    $0.syncStatus == .local || $0.syncStatus == .pending || $0.syncStatus == .failed
                }
                let kept = approvals.filter { srv in
                    !local.contains(where: { $0.id == srv.id })
                }
                store.writeApprovals(kept + local)
                store.objectWillChange.send()
            }
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    func pushQuoteApproval(_ approval: QuoteApproval) async {
        do {
            let isoFmt = ISO8601DateFormatter()
            isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            var payload: [String: AnyJSON] = [
                "id":              .string(approval.id.uuidString),
                "quote_id":        .string(approval.quoteID.uuidString),
                "company_id":      .string(approval.companyID.uuidString),
                "quote_total":     .double(NSDecimalNumber(decimal: approval.quoteTotal).doubleValue),
                "threshold_tier":  .string(approval.thresholdTier.rawValue),
                "currency":        .string(approval.currency.isEmpty ? "USD" : approval.currency),
                "requested_by":    .string(approval.requestedBy.uuidString),
                "requested_by_name": .string(approval.requestedByName),
                "requested_at":    .string(isoFmt.string(from: approval.requestedAt)),
                "status":          .string(approval.status.rawValue),
                "decision_notes":  .string(approval.decisionNotes),
                "decided_by_name": .string(approval.decidedByName),
            ]
            if let did = approval.decidedBy {
                payload["decided_by"] = .string(did.uuidString)
            } else {
                payload["decided_by"] = .null
            }
            if let dat = approval.decidedAt {
                payload["decided_at"] = .string(isoFmt.string(from: dat))
            } else {
                payload["decided_at"] = .null
            }

            try await supabase
                .from(SupabaseTable.quoteApprovals)
                .upsert(payload)
                .execute()

            await MainActor.run {
                var current = store.quoteApprovals
                if let i = current.firstIndex(where: { $0.id == approval.id }) {
                    current[i].syncStatus = .synced
                }
                store.writeApprovals(current)
            }
        } catch {
            print("⚠️ \(#function) failed for approval \(approval.id): \(error)")
            CrashReporter.capture(error: error, context: [
                "operation":  "\(#function)",
                "approval_id": approval.id.uuidString
            ])
            await MainActor.run {
                var current = store.quoteApprovals
                if let i = current.firstIndex(where: { $0.id == approval.id }) {
                    current[i].syncStatus = .failed
                }
                store.writeApprovals(current)
            }
        }
    }

    func pushPendingQuoteApprovals() async {
        let pending = await MainActor.run {
            store.quoteApprovals.filter {
                $0.syncStatus == .pending || $0.syncStatus == .local || $0.syncStatus == .failed
            }
        }
        guard !pending.isEmpty else { return }
        for a in pending {
            await pushQuoteApproval(a)
        }
    }
}
