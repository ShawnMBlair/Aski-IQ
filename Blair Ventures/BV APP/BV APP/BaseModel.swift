// BaseModel.swift
// AskiCommand – Foundation
//
// Phase 1 update: UserRole expanded from 9 to 10 roles to add `.owner`.
// `owner` already exists server-side in SQL helpers (is_estimating_admin,
// is_financial_admin, is_safety_admin, is_foreman_or_above) but was missing
// from the Swift enum, which caused any user with profiles.role='owner' to
// fall through to the default fallback at the bottom of init(from:) and
// silently demote to .fieldWorker. That dropped all elevated permissions.
// `.owner` is treated as a peer of `.executive` for approvals (level 7) and
// gets the +1 only at billing/destructive-op call sites.

import Foundation

// MARK: - Sync Status

enum SyncStatus: String, Codable {
    case local      // Created on device, never sent to server
    case pending    // Queued for upload
    case synced     // Confirmed on server
    case failed     // Upload attempted and failed
}

// MARK: - User Role (10 roles)

enum UserRole: String, Codable, CaseIterable {
    case fieldWorker    = "field_worker"
    case foreman        = "foreman"
    case safetyAdvisor  = "safety_advisor"
    case projectManager = "project_manager"
    case estimator      = "estimator"
    case officeAdmin    = "office_admin"
    case manager        = "manager"
    case executive      = "executive"
    case owner          = "owner"
    case client         = "client"

    // MARK: Display

    var displayName: String {
        switch self {
        case .fieldWorker:    return "Field Worker"
        case .foreman:        return "Foreman"
        case .safetyAdvisor:  return "Safety Advisor"
        case .projectManager: return "Project Manager"
        case .estimator:      return "Estimator"
        case .officeAdmin:    return "Office Admin"
        case .manager:        return "Manager"
        case .executive:      return "Executive"
        case .owner:          return "Owner"
        case .client:         return "Client"
        }
    }

    var description: String {
        switch self {
        case .fieldWorker:    return "Own shifts, assigned project forms and site info"
        case .foreman:        return "Crew management, timesheet approval on assigned projects"
        case .safetyAdvisor:  return "Safety inspections, incident review, compliance monitoring across all sites"
        case .projectManager: return "Full project detail, budget vs actual, field data"
        case .estimator:      return "Estimates, quotes, product library — no field data"
        case .officeAdmin:    return "Timesheets, payroll, documents, scheduling support"
        case .manager:        return "Full operations, approves estimates, quotes, change orders"
        case .executive:      return "Unrestricted access — all modules, settings, audit log"
        case .owner:          return "Account owner — billing, tenant management, all approvals"
        case .client:         return "Own project status, shared documents, approved change orders"
        }
    }

    var icon: String {
        switch self {
        case .fieldWorker:    return "hammer.fill"
        case .foreman:        return "person.badge.shield.checkmark.fill"
        case .safetyAdvisor:  return "shield.lefthalf.filled"
        case .projectManager: return "folder.badge.person.crop"
        case .estimator:      return "doc.text.magnifyingglass"
        case .officeAdmin:    return "building.2.fill"
        case .manager:        return "chart.bar.fill"
        case .executive:      return "crown.fill"
        case .owner:          return "key.fill"
        case .client:         return "person.crop.rectangle.fill"
        }
    }

    // MARK: Permission Helpers
    //
    // `.owner` is treated as a peer of `.executive` for nearly every helper —
    // both sit at approval level 7. `.owner` only diverges at the +1 surfaces
    // (`isOwner`, billing, full hard-delete authority on clients with no
    // history). See ApprovalAuthority.swift and Step 6.5 client delete guard.

    var canAccessCommercial: Bool {
        [.estimator, .manager, .executive, .owner, .officeAdmin].contains(self)
    }

    var canApproveTimesheets: Bool {
        [.foreman, .projectManager, .manager, .executive, .owner, .officeAdmin].contains(self)
    }

    var canEstimate: Bool {
        [.estimator, .manager, .executive, .owner].contains(self)
    }

    /// Domain-level base eligibility for quote approval.
    /// Tier-aware per-row gating happens in ApprovalAuthority.canApproveQuoteApproval(...).
    var canApproveQuotes: Bool {
        [.projectManager, .officeAdmin, .manager, .executive, .owner].contains(self)
    }

    var canSeeAllProjects: Bool {
        [.projectManager, .officeAdmin, .safetyAdvisor, .manager, .executive, .owner].contains(self)
    }

    var canManageUsers: Bool {
        [.manager, .executive, .owner].contains(self)
    }

    var canViewSafetyData: Bool {
        [.safetyAdvisor, .projectManager, .officeAdmin, .manager, .executive, .owner].contains(self)
    }

    var canSeePay: Bool {
        [.officeAdmin, .manager, .executive, .owner].contains(self)
    }

    /// Existing call sites use `isAdmin` to mean "executive-tier" — owner
    /// satisfies that bar. Kept as a peer flag, not an owner-only flag.
    var isAdmin: Bool {
        [.executive, .owner].contains(self)
    }

    /// Owner-only flag for the +1 surfaces that explicitly require ownership
    /// of the tenant (billing, hard-delete-with-no-history of clients,
    /// tenant offboarding from app UI). Avoid using this for approvals.
    var isOwner: Bool {
        self == .owner
    }

    var isFieldRole: Bool {
        [.fieldWorker, .foreman].contains(self)
    }

    var isExternal: Bool {
        self == .client
    }

    // MARK: CRM Permissions

    /// Can view CRM records (read-only at minimum)
    var canViewCRM: Bool {
        self != .client
    }

    /// Can create/edit opportunities, contacts, and companies
    var canEditCRM: Bool {
        ![.fieldWorker, .client].contains(self)
    }

    /// Can edit opportunity value and probability (financial fields)
    var canEditOpportunityFinancials: Bool {
        [.estimator, .projectManager, .officeAdmin, .manager, .executive, .owner].contains(self)
    }

    /// Can mark an opportunity Won or Lost
    var canMarkWonLost: Bool {
        [.projectManager, .officeAdmin, .manager, .executive, .owner].contains(self)
    }

    /// Can delete CRM records (contacts, opportunities)
    var canDeleteCRM: Bool {
        [.manager, .executive, .owner].contains(self)
    }

    /// Can delete CRM tasks
    var canDeleteCRMTasks: Bool {
        [.projectManager, .officeAdmin, .manager, .executive, .owner].contains(self)
    }

    // MARK: Phase 1 — Client lifecycle gates
    //
    // The C.2 matrix splits client deletion into three rules:
    //   • Soft-delete:                owner, executive, manager, office_admin
    //   • Hard-delete (no history):   owner, executive
    //   • Hard-delete (with history): NOBODY (DB trigger RM6 blocks even for owner)
    //
    // The "with history" path is forbidden for every authenticated user;
    // service role bypass is reserved for controlled maintenance only.

    /// Soft-delete a client (mark inactive, retain history).
    var canSoftDeleteClient: Bool {
        [.officeAdmin, .manager, .executive, .owner].contains(self)
    }

    /// Hard-delete a client THAT HAS ZERO COMMERCIAL HISTORY.
    /// Caller MUST verify dependent counts before showing this option;
    /// the DB trigger (RM6) is the final guard.
    var canHardDeleteClientWithoutHistory: Bool {
        [.executive, .owner].contains(self)
    }

    /// Always false — no authenticated user may hard-delete a client
    /// that has commercial history. Trigger RM6 enforces this server-side.
    /// Exposed as a property so call sites read self-documenting code.
    var canHardDeleteClientWithHistory: Bool { false }

    // MARK: - Slice 8: Named Workflow Permissions
    //
    // Intent-named gates that map to existing UserRole groupings per
    // the master spec's Phase 13 (Sales / Operations / Finance).
    // These are deliberately additive — no new role values, no schema
    // changes. The value is at call sites: instead of memorizing which
    // roles can do what, code reads `if role.canSendQuote { ... }`.
    //
    // Spec → existing role mapping:
    //   Sales      = estimator + manager + executive
    //   Operations = projectManager + manager + executive (+ officeAdmin where appropriate)
    //   Finance    = officeAdmin + manager + executive
    //   Admin      = executive
    //   Approver   = manager + executive

    /// Sales + Admin: kick off a new commercial opportunity in CRM.
    var canCreateOpportunity: Bool {
        [.estimator, .manager, .executive, .owner].contains(self)
    }

    /// Sales + Admin: create estimates. Alias of `canEstimate`.
    var canCreateEstimate: Bool { canEstimate }

    /// Sales + Admin: promote an estimate into a quote.
    var canPromoteEstimateToQuote: Bool {
        [.estimator, .manager, .executive, .owner].contains(self)
    }

    /// Approver-only (Slice 5 threshold tiers also apply): send a
    /// quote to a client. Alias of `canApproveQuotes` since the
    /// "approved roles" set is the same.
    var canSendQuote: Bool { canApproveQuotes }

    /// Operations + Admin: convert an accepted quote into a project.
    /// Field workers and external clients are excluded; everyone else
    /// who can edit CRM can run the conversion.
    var canConvertQuoteToProject: Bool {
        [.projectManager, .officeAdmin, .manager, .executive, .owner].contains(self)
    }

    /// Operations: create change orders against active projects.
    var canCreateChangeOrder: Bool {
        [.projectManager, .officeAdmin, .manager, .executive, .owner].contains(self)
    }

    /// Sales + Admin: approve change orders (financial impact gate).
    /// Per C.2 matrix, office_admin gets tier-gated approval rights —
    /// the per-row tier check happens in ApprovalAuthority, not here.
    var canApproveChangeOrder: Bool {
        [.officeAdmin, .manager, .executive, .owner].contains(self)
    }

    /// Finance: create + edit invoices.
    var canCreateInvoice: Bool {
        [.officeAdmin, .manager, .executive, .owner].contains(self)
    }

    /// Admin: override locked records — reopen accepted quotes,
    /// force state-machine transitions, edit historically-snapshotted
    /// data. Aligns with `isAdmin` (executive OR owner).
    var canOverrideLockedRecords: Bool { isAdmin }

    // MARK: Legacy mapping
    // Maps old 4-role values to new 8-role system
    // so existing saved data on disk still loads correctly

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        // New roles
        case "field_worker":    self = .fieldWorker
        case "foreman":         self = .foreman
        case "safety_advisor":  self = .safetyAdvisor
        case "project_manager": self = .projectManager
        case "estimator":       self = .estimator
        case "office_admin":    self = .officeAdmin
        case "manager":         self = .manager
        case "executive":       self = .executive
        case "owner":           self = .owner
        case "client":          self = .client
        // Old roles — map to closest new equivalent
        case "officeAdmin":     self = .officeAdmin
        case "management":      self = .manager
        case "admin":           self = .executive
        // Default fallback — record loudly for the role-probe diagnostic
        // and CrashReporter, then demote to the safest possible role.
        default:
            UserRole.recordUnknownRoleDecode(raw: raw)
            self = .fieldWorker
        }
    }

    /// Hook for the role-probe diagnostic + CrashReporter to detect server
    /// roles the Swift enum does not recognise. Without this, an unknown
    /// `profiles.role` value silently demotes the user to .fieldWorker
    /// and strips elevated permissions with no log line.
    ///
    /// Default implementation prints to console; RoleProbe.swift extends
    /// this to also surface in the dev-menu diagnostic and forward to
    /// CrashReporter.
    static var unknownRoleHandler: (String) -> Void = { raw in
        print("⚠️ UserRole — unknown server role '\(raw)', demoting to .fieldWorker")
    }

    static func recordUnknownRoleDecode(raw: String) {
        unknownRoleHandler(raw)
    }
}

// MARK: - Base Model Protocol

protocol BaseModel: Identifiable, Codable, Equatable {
    var id: UUID { get }
    var externalID: String? { get set }
    var createdAt: Date { get }
    var updatedAt: Date { get set }
    var syncStatus: SyncStatus { get set }
    var lastModifiedBy: String { get set }
    var lastModifiedAt: Date { get set }
}

// MARK: - Audit Snapshot

struct AuditSnapshot: Codable, Identifiable {
    let id: UUID
    let entityType: String
    let entityID: UUID
    let eventType: String
    let snapshotData: Data
    let createdAt: Date
    let createdBy: String
    var companyID: UUID? = nil
    var syncStatus: SyncStatus = .pending
}
