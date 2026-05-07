// TenantProfilesSync.swift
// Aski IQ — pulls every profile in the current tenant so iOS can
// resolve approver emails directly (instead of always blasting a
// shared company inbox).
//
// SECURITY MODEL
// The `profiles` RLS policy `profiles_company_read` already permits
// any authenticated tenant member to SELECT all profiles in their
// own company:
//
//   ((id = auth.uid()) OR (company_id = get_my_company_id()))
//
// So this is a straight pull — no special role required, no extra
// RPC. Only fields exposed are the public ones we already model on
// AppUserProfile (id / email / full_name / role / is_active /
// company_id / created_at).
//
// USAGE
// • SyncEngine.pullCompanyProfiles() — populates store.tenantProfiles
// • AppStore.approverEmails(for: ApprovalThreshold.Tier) — returns
//   distinct emails for managers / executives matching the tier
// • Hook the pull into the launch sync (pullAll) so the cache is
//   warm by the time the first approval is requested.

import Foundation
import Supabase

extension SyncEngine {

    /// Pulls every profile row in the current tenant. Idempotent — the
    /// @Published array is replaced wholesale on each call. Failures
    /// are logged but never throw; an empty cache means
    /// approverEmails(forTier:) falls back to the company inbox in
    /// QuoteApprovalNotifier (its existing behaviour).
    func pullCompanyProfiles() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            let rows: [AppUserProfile] = try await supabase
                .from(SupabaseTable.profiles)
                .select()
                .eq("company_id", value: companyID.uuidString)
                .execute()
                .value
            await MainActor.run {
                // Drop inactive profiles so the approver cache only
                // ever surfaces people who can actually act on the
                // approval. Inactive rows stay queryable via direct
                // SQL if needed for audit purposes.
                store.tenantProfiles = rows.filter { $0.isActive }
            }
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }
}

extension AppStore {

    /// Returns distinct, non-empty email addresses for every active
    /// tenant profile whose role can satisfy the supplied approval
    /// tier (manager → manager + executive; admin → executive only).
    /// Used by QuoteApprovalNotifier to route per-user emails.
    ///
    /// Returns an empty array when `tenantProfiles` hasn't been
    /// populated yet (cold launch before first sync). Caller falls
    /// back to the company inbox in that case.
    func approverEmails(for tier: ApprovalThreshold.Tier) -> [String] {
        let matching = tenantProfiles.filter { profile in
            ApprovalThreshold.canApprove(tier: tier, role: profile.role)
        }
        var seen = Set<String>()
        var out: [String] = []
        for p in matching {
            let trimmed = p.email.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  seen.insert(trimmed.lowercased()).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }
}
