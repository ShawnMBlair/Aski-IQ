// CommercialContext.swift
// Aski IQ — Shared Commercial Context Model
//
// Carried through the entire commercial creation workflow.
// Populated by CommercialIntakeView, passed to every create view,
// and used to auto-link CRM opportunities, clients, and projects.

import Foundation
import SwiftUI

// MARK: - Context Source

/// Where a commercial workflow originated.
enum CommercialContextSource: String, Codable {
    case intake          = "intake"           // "New Commercial Work" from More tab
    case fromOpportunity = "from_opportunity" // Tapped "Create" inside a CRM opportunity
    case fromClient      = "from_client"      // Tapped "New Work" inside a client record
    case fromProject     = "from_project"     // Tapped "New Work" inside a project
    case fromQuote       = "from_quote"       // Converting a quote
    case fromEstimate    = "from_estimate"    // Converting an estimate
    case fromMaterialSale = "from_material_sale"

    var label: String {
        switch self {
        case .intake:           return "New Work"
        case .fromOpportunity:  return "From CRM"
        case .fromClient:       return "From Client"
        case .fromProject:      return "From Project"
        case .fromQuote:        return "From Quote"
        case .fromEstimate:     return "From Estimate"
        case .fromMaterialSale: return "From Material Sale"
        }
    }
}

// MARK: - Commercial Context

/// Shared context model threaded through the full commercial creation flow.
/// All fields are optional — they fill in progressively as the user works through
/// CommercialIntakeView steps. Downstream create views use the context to
/// pre-populate fields and skip pickers the user has already answered.
///
/// Codable so wizard-in-progress state can be persisted across app crashes via
/// `saveDraft()` / `loadDraft()`. The intake view auto-saves on every mutation
/// and clears the draft on successful submit or explicit cancel.
struct CommercialContext: Codable {

    // Work Type
    var workType: SaleType? = nil

    // Client
    var clientID:   UUID?   = nil
    var clientName: String  = ""

    // Contact
    var contactID:   UUID?  = nil
    var contactName: String = ""

    // Site
    var siteID:      UUID?  = nil
    var siteAddress: String = ""

    // CRM
    var opportunityID:    UUID?  = nil
    var opportunityTitle: String = ""

    // Project
    var projectID:   UUID?  = nil
    var projectName: String = ""

    // Linked records (pre-created before routing)
    var estimateID: UUID? = nil
    var quoteID:    UUID? = nil

    // Workflow metadata
    var source: CommercialContextSource = .intake

    // MARK: - Computed

    /// True when the context has enough info to auto-create a CRM opportunity.
    var canAutoCreateOpportunity: Bool {
        clientID != nil && workType != nil
    }

    /// True when the minimum required fields are present to save a commercial record.
    var isMinimallyComplete: Bool {
        clientID != nil
    }

    /// True when the context carries a live CRM opportunity link.
    var hasCRMLink: Bool { opportunityID != nil }

    /// True when the context carries a live project link.
    var hasProjectLink: Bool { projectID != nil }

    /// A short human-readable summary for the context bar.
    var summaryLine: String {
        var parts: [String] = []
        if !clientName.isEmpty        { parts.append(clientName) }
        if !opportunityTitle.isEmpty  { parts.append(opportunityTitle) }
        else if !projectName.isEmpty  { parts.append(projectName) }
        if let wt = workType          { parts.append(wt.displayName) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Convenience Builders

    /// Creates a blank context from the More tab intake.
    static func blank() -> CommercialContext { CommercialContext() }

    /// Creates a context pre-filled from a CRM opportunity.
    static func from(
        opportunity: CRMOpportunity,
        clientName: String,
        workType: SaleType? = nil
    ) -> CommercialContext {
        CommercialContext(
            workType:         workType,
            clientID:         opportunity.clientID,
            clientName:       clientName,
            contactID:        opportunity.contactID,
            opportunityID:    opportunity.id,
            opportunityTitle: opportunity.title,
            source:           .fromOpportunity
        )
    }

    /// Creates a context pre-filled from a Client record.
    static func from(client: Client, workType: SaleType? = nil) -> CommercialContext {
        CommercialContext(
            workType:   workType,
            clientID:   client.id,
            clientName: client.name,
            source:     .fromClient
        )
    }

    /// Creates a context pre-filled from a Project.
    static func from(project: Project, clientName: String, workType: SaleType? = nil) -> CommercialContext {
        CommercialContext(
            workType:    workType,
            clientID:    project.clientID,   // UUID? — optional on Project
            clientName:  clientName,
            projectID:   project.id,
            projectName: project.name,
            source:      .fromProject
        )
    }

    // MARK: - Draft Persistence

    /// Key version bumped from v1 → v2 to silently invalidate any
    /// drafts left behind by builds that pre-date the
    /// `suppressDraftSave` race fix. Devices upgrading from a buggy
    /// build had stale drafts in UserDefaults that satisfied the
    /// resume-prompt criteria, so the prompt fired on every intake
    /// open even though the new code path no longer creates such
    /// drafts. Bumping the key means `loadDraft()` looks at v2
    /// (empty), returns nil, and `legacyKeyCleanup()` evicts the
    /// orphaned v1 entry.
    private static let draftKey   = "aski_commercial_intake_draft_v2"
    private static let draftTSKey = "aski_commercial_intake_draft_ts_v2"

    /// Old keys we evict on every load so they don't accumulate
    /// in UserDefaults. Add to this list whenever the version bumps.
    private static let legacyDraftKeys: [String] = [
        "aski_commercial_intake_draft_v1",
        "aski_commercial_intake_draft_ts_v1"
    ]

    /// One-shot cleanup of pre-v2 keys. Idempotent — safe to call on
    /// every load. Once every active device has run this at least
    /// once, the legacy entries are gone for good.
    private static func legacyKeyCleanup() {
        let defaults = UserDefaults.standard
        for key in legacyDraftKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
            print("🧹 CommercialContext: evicted legacy draft key '\(key)'")
        }
    }

    /// How long an in-progress draft is considered fresh enough to surface
    /// the resume prompt. Beyond this window, a forgotten partial intake
    /// is just noise — better to clear it silently and let the user start
    /// with a clean slate.
    private static let draftMaxAge: TimeInterval = 60 * 60   // 1 hour

    /// True when there's enough useful state in this context that resuming
    /// a wizard would be worth offering to the user. Pre-fix this used OR
    /// across every field, so a single tap on a work-type tile was enough
    /// to leave a "resumable draft" that nagged forever. Now requires
    /// BOTH a work type AND a client — i.e. the user got past step 1
    /// AND past step 2 of the intake wizard. A user who just opened the
    /// hub and tapped one tile to look at the options no longer triggers
    /// a draft save.
    var hasResumableContent: Bool {
        workType != nil && (clientID != nil || !clientName.isEmpty)
    }

    /// Save the current wizard state to UserDefaults so a crash mid-intake
    /// can be resumed on next launch. Stamps a timestamp alongside the
    /// payload so `loadDraft()` can age out forgotten drafts.
    func saveDraft() {
        guard hasResumableContent else { return }
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.draftKey)
            UserDefaults.standard.set(Date(), forKey: Self.draftTSKey)
        }
    }

    /// Load any previously-saved draft. Returns nil if:
    ///   • no draft has been saved
    ///   • the saved draft fails to decode
    ///   • the draft no longer meets `hasResumableContent` (defensive —
    ///     handles the case where a user upgraded from a build that
    ///     used the looser old check)
    ///   • the draft is older than `draftMaxAge`
    /// In the latter two cases the stale draft is also evicted so the
    /// user isn't quietly carrying around dead state.
    static func loadDraft() -> CommercialContext? {
        // Sweep up any legacy keys before we look at the current one.
        // Cheap (one UserDefaults check per key), idempotent, and runs
        // exactly when we need it — first time a user opens intake on
        // the new build.
        legacyKeyCleanup()

        guard let data = UserDefaults.standard.data(forKey: draftKey),
              let ctx  = try? JSONDecoder().decode(CommercialContext.self, from: data) else {
            return nil
        }

        guard ctx.hasResumableContent else {
            clearDraft()
            return nil
        }

        let ts = UserDefaults.standard.object(forKey: draftTSKey) as? Date
        if let ts, Date().timeIntervalSince(ts) > draftMaxAge {
            clearDraft()
            return nil
        }

        return ctx
    }

    /// Clears any saved draft. Call on successful submit or explicit cancel.
    /// Also opportunistically evicts legacy keys — every clear is a
    /// chance to clean up.
    static func clearDraft() {
        UserDefaults.standard.removeObject(forKey: draftKey)
        UserDefaults.standard.removeObject(forKey: draftTSKey)
        legacyKeyCleanup()
    }
}

// MARK: - Commercial Context Bar

/// Persistent context indicator shown at the top of all commercial create views.
/// Shows what client / opportunity / project this record will be linked to.
struct CommercialContextBar: View {
    let context: CommercialContext

    var body: some View {
        if context.clientID != nil || context.opportunityID != nil || context.projectID != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "link.circle.fill")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Text("Linked to")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 12) {
                    if context.clientID != nil {
                        contextChip(
                            icon: "building.2.fill",
                            label: context.clientName.isEmpty ? "Client" : context.clientName,
                            color: .blue
                        )
                    }
                    if context.opportunityID != nil {
                        contextChip(
                            icon: "chart.line.uptrend.xyaxis",
                            label: context.opportunityTitle.isEmpty ? "Opportunity" : context.opportunityTitle,
                            color: .orange
                        )
                    }
                    if context.projectID != nil {
                        contextChip(
                            icon: "folder.fill",
                            label: context.projectName.isEmpty ? "Project" : context.projectName,
                            color: .green
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.blue.opacity(0.06))
            .overlay(
                Rectangle()
                    .frame(height: 2)
                    .foregroundColor(.blue.opacity(0.25)),
                alignment: .bottom
            )
        }
    }

    @ViewBuilder
    private func contextChip(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
            Text(label)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .cornerRadius(6)
    }
}

// MARK: - Validation

extension AppStore {

    /// Returns a list of validation error strings. Empty array means the save is allowed.
    /// Call this before allowing a save in any commercial create view.
    func validateBeforeSave(context: CommercialContext, for workType: SaleType) -> [String] {
        var errors: [String] = []

        // Every commercial record requires a client
        if context.clientID == nil {
            errors.append("A client is required before saving.")
        }

        // Project work and service work should have a CRM opportunity
        if (workType == .projectWork || workType == .serviceWork) && context.opportunityID == nil {
            // This is a warning — soft enforcement. We auto-create on save so this
            // should only fire if auto-create failed.
            // (Omitted from hard errors — handled by ensureCommercialContext)
        }

        // Change orders always require a project
        // (enforced at call site in ChangeOrderViews — context must have projectID)

        return errors
    }

    /// Fills in any missing context fields that can be inferred from the store.
    /// Returns the updated context. Does NOT save anything — callers must persist.
    func ensureCommercialContext(_ context: inout CommercialContext) {

        // If we have an opportunity but no client, pull the client from the opportunity
        if context.clientID == nil, let oppID = context.opportunityID,
           let opp = crmOpportunities.first(where: { $0.id == oppID }) {
            context.clientID = opp.clientID
            if context.clientName.isEmpty,
               let client = client(id: opp.clientID) {
                context.clientName = client.name
            }
        }

        // If we have a project but no client, pull from project
        if context.clientID == nil, let projID = context.projectID,
           let proj = projects.first(where: { $0.id == projID }),
           let projClientID = proj.clientID {
            context.clientID = projClientID
            if let client = client(id: projClientID), context.clientName.isEmpty {
                context.clientName = client.name
            }
        }

        // If we have a project but no opportunity, look for a linked opportunity
        if context.opportunityID == nil, let projID = context.projectID {
            if let opp = crmOpportunities.first(where: { $0.projectID == projID }) {
                context.opportunityID = opp.id
                if context.opportunityTitle.isEmpty {
                    context.opportunityTitle = opp.title
                }
            }
        }
    }

    /// Auto-creates a CRM opportunity from context. Saves it to the store and
    /// returns the opportunity. Updates `context.opportunityID` and `context.opportunityTitle`.
    @discardableResult
    func createOpportunityFromContext(_ context: inout CommercialContext) -> CRMOpportunity? {
        guard let clientID = context.clientID else { return nil }
        guard context.opportunityID == nil else {
            // Already exists — return the existing one
            return crmOpportunities.first(where: { $0.id == context.opportunityID })
        }

        let workTypeLabel = context.workType?.displayName ?? "Work"
        let clientLabel   = context.clientName.isEmpty ? "Client" : context.clientName
        let title         = "\(workTypeLabel) — \(clientLabel)"

        var opp = CRMOpportunity(clientID: clientID)
        opp.title        = title
        opp.stage        = .newLead
        opp.probability  = OpportunityStage.newLead.defaultProbability
        opp.serviceType  = context.workType?.displayName ?? ""
        opp.siteAddress  = context.siteAddress
        opp.contactID    = context.contactID
        opp.projectID    = context.projectID
        opp.source       = .directInquiry

        upsertCRMOpportunity(opp)

        context.opportunityID    = opp.id
        context.opportunityTitle = opp.title

        logCRMActivity(
            type:          .leadCreated,
            title:         "Opportunity created from \(context.source.label)",
            notes:         "",
            clientID:      clientID,
            contactID:     context.contactID,
            opportunityID: opp.id,
            quoteID:       nil,
            projectID:     context.projectID
        )

        return opp
    }
}
