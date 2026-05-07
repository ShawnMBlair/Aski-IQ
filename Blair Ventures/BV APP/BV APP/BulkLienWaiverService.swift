// BulkLienWaiverService.swift
// Aski IQ — Send N lien waiver requests in one action.
//
// PROBLEM
// On a project with 8 subs each getting monthly progress payments,
// minting and sending waivers one at a time is 24+ taps per cycle —
// exactly the kind of repetitive work that admins skip, leaving the
// company exposed to surprise mechanic's liens.
//
// SOLUTION
// Pick N recipients (subs + suppliers), set the common terms once
// (waiver type, through date, payment ref), enter per-row amounts,
// hit "Create + Send". For each recipient the service:
//
//   1. Creates a `LienWaiver` row (status = 'requested')
//   2. Mints a magic-link token (status flips to 'sent')
//   3. Sends a personalized email with the link via send-email
//
// PARTIAL-SUCCESS HANDLING
// Each recipient is processed independently. The Result array tells
// the caller which ones succeeded and which failed (and why), so a
// single bad email address doesn't block the rest.

import Foundation

@MainActor
final class BulkLienWaiverService {

    static let shared = BulkLienWaiverService()
    private init() {}

    // MARK: - Recipient

    /// Recipient candidate. Use `from(subcontractor:)` and
    /// `from(supplier:)` to derive these — never construct directly.
    struct Recipient: Identifiable, Equatable {
        let id: UUID                  // matches the source sub/supplier id
        let kind: Kind
        let displayName: String
        let email: String?
        let trade: String?

        enum Kind: String { case subcontractor, supplier }

        var hasEmail: Bool { email?.isEmpty == false }

        static func from(_ s: Subcontractor) -> Recipient {
            Recipient(
                id:          s.id,
                kind:        .subcontractor,
                displayName: s.companyName,
                email:       s.email,
                trade:       s.trade
            )
        }

        static func from(_ s: Supplier) -> Recipient {
            Recipient(
                id:          s.id,
                kind:        .supplier,
                displayName: s.name,
                email:       s.email.isEmpty ? nil : s.email,
                trade:       nil
            )
        }
    }

    // MARK: - Common params

    /// Shared waiver fields. Each recipient gets its own per-row amount.
    struct CommonParams {
        let contractID:       UUID?
        let waiverType:       LienWaiverType
        let throughDate:      Date?
        let paymentReference: String?
        let currency:         String
    }

    /// Per-recipient outcome.
    struct RecipientResult: Identifiable {
        let id: UUID                  // recipient.id
        let displayName: String
        let outcome: Outcome
        enum Outcome {
            case success(waiverID: UUID, magicURL: URL)
            case skippedNoEmail
            case createFailed(String)
            case mintFailed(String)
            case emailFailed(String)
        }
    }

    enum BulkError: Error, LocalizedError {
        case notAdmin
        var errorDescription: String? {
            switch self {
            case .notAdmin: return "Only admins can send waiver requests."
            }
        }
    }

    // MARK: - Run the bulk send

    /// Runs the create → mint → send pipeline for each recipient.
    /// Returns a per-recipient result array so the UI can show partial
    /// success ("Sent 4 of 5 — 1 failed").
    func sendBulk(
        recipients: [(Recipient, amount: Decimal?)],
        common:     CommonParams,
        in store:   AppStore
    ) async throws -> [RecipientResult] {
        guard store.currentUserRole.isAdmin else { throw BulkError.notAdmin }

        var out: [RecipientResult] = []

        for (recipient, amount) in recipients {
            let result = await processOne(
                recipient: recipient,
                amount:    amount,
                common:    common,
                store:     store
            )
            out.append(result)
        }
        return out
    }

    // MARK: - Internals

    private func processOne(
        recipient: Recipient,
        amount:    Decimal?,
        common:    CommonParams,
        store:     AppStore
    ) async -> RecipientResult {
        guard recipient.hasEmail, let email = recipient.email else {
            return RecipientResult(
                id: recipient.id,
                displayName: recipient.displayName,
                outcome: .skippedNoEmail
            )
        }

        // 1. Create the waiver row.
        var waiver = LienWaiver(
            waiverType:     common.waiverType,
            waiverFromName: recipient.displayName
        )
        waiver.contractID       = common.contractID
        waiver.waiverFromID     = recipient.id
        waiver.waiverFromEmail  = email
        waiver.throughDate      = common.throughDate
        waiver.amount           = amount
        waiver.paymentReference = common.paymentReference
        waiver.currency         = common.currency
        waiver.status           = .requested
        let saved = store.upsertLienWaiver(waiver)

        // 2. Mint magic-link token.
        let mint: LienWaiverAcceptanceService.MintResult
        do {
            mint = try await LienWaiverAcceptanceService.shared.mintToken(waiverID: saved.id)
        } catch {
            return RecipientResult(
                id: recipient.id,
                displayName: recipient.displayName,
                outcome: .mintFailed(error.localizedDescription)
            )
        }

        // 3. Send the email with the personalized magic link.
        let body = composeBody(
            recipient:  recipient,
            common:     common,
            amount:     amount,
            url:        mint.url,
            companyName: AppSettings.shared.companyName
        )
        let subject = composeSubject(common: common, companyName: AppSettings.shared.companyName)

        let mailResult = await EmailService.shared.sendText(
            to:         [email],
            subject:    subject,
            bodyText:   body,
            entityType: "lien_waiver",
            entityID:   saved.id
        )
        switch mailResult {
        case .success:
            return RecipientResult(
                id: recipient.id,
                displayName: recipient.displayName,
                outcome: .success(waiverID: saved.id, magicURL: mint.url)
            )
        case .failure(let err):
            return RecipientResult(
                id: recipient.id,
                displayName: recipient.displayName,
                outcome: .emailFailed(err.userMessage)
            )
        }
    }

    private func composeSubject(common: CommonParams, companyName: String) -> String {
        let typeLabel = common.waiverType.displayName.lowercased()
        return "Lien waiver request — \(typeLabel) — \(companyName)"
    }

    private func composeBody(
        recipient:   Recipient,
        common:      CommonParams,
        amount:      Decimal?,
        url:         URL,
        companyName: String
    ) -> String {
        let typeLabel = common.waiverType.displayName
        let amountStr: String
        if let amount {
            let f = NumberFormatter()
            f.numberStyle = .currency
            f.currencyCode = common.currency
            amountStr = f.string(from: NSDecimalNumber(decimal: amount)) ?? "$\(amount)"
        } else {
            amountStr = "amount TBD"
        }
        let throughLine: String
        if let d = common.throughDate {
            let f = DateFormatter(); f.dateStyle = .long
            throughLine = "Through date: \(f.string(from: d))\n"
        } else {
            throughLine = ""
        }
        let payRef: String = (common.paymentReference?.isEmpty == false)
            ? "Payment reference: \(common.paymentReference!)\n"
            : ""

        return """
        Hi \(recipient.displayName),

        \(companyName) is requesting your signed \(typeLabel.lowercased()) lien waiver for the payment listed below.

        Amount: \(amountStr)
        \(throughLine)\(payRef)
        Click here to review and sign:
        \(url.absoluteString)

        The signing page explains the waiver in plain English before you sign — important if this is an unconditional or final waiver. The link is unique to you and expires in 30 days.

        — \(companyName)
        """
    }
}
