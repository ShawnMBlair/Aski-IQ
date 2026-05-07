// LienWaiver.swift
// Aski IQ — Per-payment lien waiver tracking.
//
// WHY THIS EXISTS
// Lien waivers are the single highest-leverage payment protection a
// GC has against subs filing surprise mechanic's liens — and the
// single highest-risk thing a sub or supplier can sign without
// reading. Mismanaged waivers cost everyone:
//   * GC gives an unconditional waiver before the wire actually clears
//     → sub waived their lien rights for nothing
//   * Sub loses track of which waivers they've signed → can't enforce
//     when payment never lands
//   * Supplier signs "final waiver" thinking it's progress → permanent
//     loss of all rights on the project
//
// This module captures every waiver as a structured record tied to a
// contract + invoice + payment, with optional digital signature
// collection via the magic-link pattern.
//
// FOUR TYPES
//   progress_conditional   — "I waive lien rights through X IF I get paid Y"
//   progress_unconditional — "I have been paid Y, lien rights waived through X"
//   final_conditional      — "I waive ALL rights IF I get paid Y"
//   final_unconditional    — "I have been paid in full, all rights gone"
//
// LIFECYCLE
//   requested  — admin asked for it (created it locally, no link sent yet)
//   sent       — magic link minted + emailed to sub
//   pending    — link clicked but not yet signed
//   received   — signed, recorded, paper trail complete
//   rejected   — sub refused to sign
//   expired    — link timed out without signature
//   replaced   — superseded by a new waiver (e.g. amount changed)

import Foundation

// MARK: - Type / Status enums

enum LienWaiverType: String, Codable, CaseIterable, Identifiable {
    case progressConditional   = "progress_conditional"
    case progressUnconditional = "progress_unconditional"
    case finalConditional      = "final_conditional"
    case finalUnconditional    = "final_unconditional"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .progressConditional:   return "Progress · Conditional"
        case .progressUnconditional: return "Progress · Unconditional"
        case .finalConditional:      return "Final · Conditional"
        case .finalUnconditional:    return "Final · Unconditional"
        }
    }

    /// The risk level for the SIGNER. Conditional = low (you only waive
    /// if paid). Unconditional = high (you waive whether paid or not —
    /// only sign after funds clear). Used to color-code the picker.
    var signerRiskLevel: RiskLevel {
        switch self {
        case .progressConditional, .finalConditional:     return .low
        case .progressUnconditional:                      return .medium
        case .finalUnconditional:                         return .critical
        }
    }

    /// Plain-English explanation surfaced under the picker so a new
    /// admin understands which type to send and when.
    var helperText: String {
        switch self {
        case .progressConditional:
            return "Sub waives lien rights through a date IF they receive the named amount. Safe — only takes effect when payment clears."
        case .progressUnconditional:
            return "Sub waives lien rights through a date REGARDLESS. Only request after the wire / check has cleared."
        case .finalConditional:
            return "Sub waives ALL lien rights on this project IF they receive the named amount. Used at project closeout, contingent on final payment."
        case .finalUnconditional:
            return "Sub waives ALL lien rights, period. Use only after final payment has cleared. Permanent."
        }
    }
}

enum LienWaiverStatus: String, Codable, CaseIterable {
    case requested
    case sent
    case pending
    case received
    case rejected
    case expired
    case replaced

    var displayName: String { rawValue.capitalized }

    var color: String {
        switch self {
        case .requested: return "secondary"
        case .sent:      return "blue"
        case .pending:   return "orange"
        case .received:  return "green"
        case .rejected:  return "red"
        case .expired:   return "red"
        case .replaced:  return "secondary"
        }
    }

    /// Lifecycle states that count toward "still need attention".
    var isOpen: Bool {
        switch self {
        case .requested, .sent, .pending: return true
        default: return false
        }
    }
}

// MARK: - LienWaiver

struct LienWaiver: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var companyID: UUID? = nil
    var contractID: UUID?
    var invoiceID: UUID?
    var paymentReference: String?

    var waiverType: LienWaiverType

    // Identity of the waiving party
    var waiverFromName: String
    var waiverFromID: UUID?
    var waiverFromEmail: String?
    var waiverToName: String?

    // Money
    var throughDate: Date?
    var amount: Decimal?
    var retainageExcluded: Decimal? = 0
    var currency: String = "USD"

    // Lifecycle
    var status: LienWaiverStatus = .requested
    var requestedAt: Date = Date()
    var sentAt: Date?
    var signedAt: Date?
    var receivedAt: Date?

    // Capture (digital signing)
    var signatureDataURL: String?
    var signedByName: String?
    var signedByEmail: String?
    var signedByIP: String?
    var signedUserAgent: String?

    // Document
    var documentURL: String?
    var documentFilename: String?

    // Magic link
    var magicLinkToken: String?
    var magicLinkExpiresAt: Date?
    var magicLinkSentAt: Date?
    var magicLinkRevokedAt: Date?

    // Audit
    var notes: String?
    var createdBy: UUID?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var syncStatus: SyncStatus = .local
    // MARK: Sample data tracking
    // Populated only by SampleDataSeeder; immutable post-insert via DB
    // trigger. Cleared along with the row when an executive runs Clear
    // Sample Data. See SampleData/SampleDataTypes.swift.
    var isSampleData:           Bool      = false
    var sampleDataBatchID:      UUID?     = nil
    var sampleDataSeedVersion:  String?   = nil
    var sampleDataCreatedAt:    Date?     = nil
    var sampleDataCreatedBy:    UUID?     = nil

    var isDeleted: Bool = false

    /// Has the waiver actually been received (signed + on file).
    var isReceived: Bool { status == .received }

    /// True for conditional waivers (the timing-safer kind).
    var isConditional: Bool {
        waiverType == .progressConditional || waiverType == .finalConditional
    }
}

// MARK: - Sample-data tracking
extension LienWaiver: SampleDataTrackable {}
