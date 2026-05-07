// QuoteApprovalNotifier.swift
// Aski IQ — Slice 5 follow-up: notifications for quote approval workflow
//
// Slice 5 shipped the approval threshold gate but had no way to surface
// pending approvals to managers — they had to manually open Settings →
// Pending Approvals to see anything. This notifier fires:
//
//   • email + local push when an approval is REQUESTED:
//     → goes to company inbox (AppSettings.shared.companyEmail) so the
//       admin team is notified server-side
//     → local push on the requesting rep's device as confirmation
//
//   • email + local push when an approval is DECIDED (approve / reject):
//     → goes to company inbox so everyone has a record
//     → local push on the deciding manager's device as confirmation
//
// SCOPE NOTE
// Direct-to-approver routing (a manager's personal email when an
// approval lands in their queue) needs an auth.users → Employee.email
// mapping that doesn't exist in the iOS model today. Slice 8 (or
// whoever ships it) can add that later. For now the company inbox is
// the durable channel; the in-app Pending Approvals list (Slice 5)
// is the per-user view.

import Foundation

@MainActor
enum QuoteApprovalNotifier {

    enum Event {
        case requested(QuoteApproval, Quote)
        case approved(QuoteApproval, Quote)
        case rejected(QuoteApproval, Quote)
    }

    /// Fire-and-forget. Sends:
    ///   1. A local push on the current device
    ///   2. Direct emails to the matching approvers (managers /
    ///      executives whose role can satisfy the tier) when their
    ///      profile cache has been populated
    ///   3. A fallback email to the company inbox when no individual
    ///      approver emails are available — covers cold-launch race
    ///      conditions and tenants that haven't fully onboarded
    ///
    /// Direct-to-approver routing is the upgrade. Pre-fix this only
    /// hit the company inbox; managers had to manually open Settings
    /// → Pending Approvals to know an approval was waiting.
    static func notify(_ event: Event) {
        let store = AppStore.shared

        let title:   String
        let summary: String
        let pushID:  String
        let tier:    ApprovalThreshold.Tier
        let entityID: UUID

        switch event {
        case .requested(let approval, let quote):
            title = "Quote approval requested"
            summary = "\(approval.requestedByName.isEmpty ? "A team member" : approval.requestedByName) " +
                      "needs \(approval.thresholdTier.displayName.lowercased()) on " +
                      "quote \(quote.jobNumber) (\(approval.quoteTotalString)) for \(quote.clientName)."
            pushID = "approval_requested_\(approval.id.uuidString)"
            tier   = approval.thresholdTier
            entityID = quote.id

        case .approved(let approval, let quote):
            title = "Quote approval granted"
            summary = "\(approval.decidedByName.isEmpty ? "A manager" : approval.decidedByName) " +
                      "approved quote \(quote.jobNumber) for \(quote.clientName) " +
                      "(\(approval.quoteTotalString)). It can now be sent."
            pushID = "approval_decided_\(approval.id.uuidString)"
            tier   = approval.thresholdTier
            entityID = quote.id

        case .rejected(let approval, let quote):
            title = "Quote approval rejected"
            summary = "\(approval.decidedByName.isEmpty ? "A manager" : approval.decidedByName) " +
                      "rejected quote \(quote.jobNumber) for \(quote.clientName) " +
                      "(\(approval.quoteTotalString)). " +
                      (approval.decisionNotes.isEmpty ? "" : "Reason: \(approval.decisionNotes)")
            pushID = "approval_decided_\(approval.id.uuidString)"
            tier   = approval.thresholdTier
            entityID = quote.id
        }

        // Local push — always fire, regardless of email config.
        NotificationManager.shared.sendLocalNotification(
            title:      title,
            body:       summary,
            identifier: pushID
        )

        // Build recipient list. Priority:
        //   1. Individual approver emails (per-user routing)
        //   2. Company inbox as fallback / addition
        // For .requested events: only email the eligible approvers.
        // For .approved / .rejected events: also CC the requester so
        // they know what happened — but we don't have the requester's
        // direct email mapping from approval.requestedBy (UUID), so
        // we add the company inbox as the durable channel.
        var recipients: [String] = []
        var seen = Set<String>()

        let approverEmails = store.approverEmails(for: tier)
        for email in approverEmails {
            if seen.insert(email.lowercased()).inserted { recipients.append(email) }
        }

        let companyEmail = AppSettings.shared.companyEmail.trimmingCharacters(in: .whitespaces)
        if !companyEmail.isEmpty,
           seen.insert(companyEmail.lowercased()).inserted {
            recipients.append(companyEmail)
        }

        guard !recipients.isEmpty else {
            // No emails configured anywhere — local push is the only
            // surface this notification has. Acceptable for tenants
            // that haven't set up email yet; the in-app Pending
            // Approvals list (Slice 5) is the per-user backstop.
            print("ℹ️ QuoteApprovalNotifier: no recipients (cache empty + no company inbox); push-only delivery")
            return
        }

        let html = EmailHTMLTemplate.wrap(
            plainText:  summary,
            companyName: AppSettings.shared.companyName,
            subject:    title,
            footerNote: "Open Aski IQ → Settings → Pending Approvals to act on this."
        )

        Task { @MainActor in
            let result = await EmailService.shared.sendText(
                to:         recipients,
                subject:    title,
                bodyText:   summary,
                bodyHTML:   html,
                entityType: "quote_approval",
                entityID:   entityID
            )
            if case .failure(let err) = result {
                print("⚠️ QuoteApprovalNotifier: email send failed: \(err.userMessage)")
            }
        }
    }
}
