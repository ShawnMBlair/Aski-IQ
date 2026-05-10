// MultiCompany.swift
// Aski IQ — Phase 8 / Multi-Company / Track 3
//
// v1 scope: surface the list of companies the signed-in user has
// access to and let them switch between them without re-authenticating.
// Save pending writes, swap `currentCompanyID`, re-attach local
// persistence, and trigger a full re-pull. UI lives in the
// `CompanySwitcherSheet` below, surfaced from AppSettings.
//
// Server dependency (not in this slice):
//   Real multi-company support requires either (a) a
//   `company_memberships` table mapping each user to N companies, or
//   (b) RLS on `companies` that allows a user to see every company
//   they belong to. Aski IQ today scopes most users to a single
//   company via `get_my_company_id()` — for those users the pull
//   returns 1 row and the switcher is a no-op. The UI is built so
//   that when the server-side membership model is added, no further
//   iOS changes are needed.

import SwiftUI

// MARK: - Membership Model

/// One row in the user's list of accessible companies. Lightweight by
/// design — full company profile data still lives in `tenantProfiles`
/// and the various data tables.
struct CompanyMembership: Identifiable, Equatable, Codable {
    let id: UUID                  // matches `companies.id`
    var name: String
    var isCurrent: Bool = false   // derived from `AppStore.currentCompanyID`

    /// Display label for the switcher row. Falls back to the UUID
    /// suffix when the server hasn't sent a name yet (e.g., a
    /// freshly inserted company).
    var displayName: String {
        name.isEmpty ? "Company \(id.uuidString.prefix(8))" : name
    }
}

// MARK: - AppStore Multi-Company API

extension AppStore {

    /// Pulls the user's accessible companies via the `companies` table.
    /// RLS filters server-side to the rows this user can see. For
    /// single-membership users this returns a 1-row list and the
    /// switcher just confirms the active tenant; for true
    /// multi-tenant users (post server-side enablement) it lights up
    /// the full set.
    ///
    /// Idempotent: calling this multiple times is cheap and replaces
    /// the local cache each time. Safe to invoke after every login
    /// and after `switchToCompany(_:)`.
    @MainActor
    func pullCompanyMemberships() async {
        struct Row: Codable {
            let id: String
            let name: String?
        }
        do {
            let rows: [Row] = try await SyncEngine.shared.client.select(
                Row.self,
                from: SupabaseTable.companies,
                filters: [],
                orderBy: "name",
                ascending: true
            )
            let mapped: [CompanyMembership] = rows.compactMap { row in
                guard let uuid = UUID(uuidString: row.id) else { return nil }
                return CompanyMembership(
                    id: uuid,
                    name: row.name ?? "",
                    isCurrent: uuid == self.currentCompanyID
                )
            }
            self.companyMemberships = mapped
        } catch {
            // Soft-fail: leave the existing list in place. The settings
            // sheet shows a hint when the list is empty so the user
            // knows it didn't load.
            print("⚠️ pullCompanyMemberships failed: \(error)")
        }
    }

    /// Switches the active company. Must be called from a user-driven
    /// action (button tap), not from a background sync, because it
    /// flushes pending writes synchronously and wipes in-memory
    /// caches before the next pull lands.
    ///
    /// Steps:
    ///   1. Flush pending writes for the OUTGOING tenant so they aren't
    ///      lost or merged into the wrong tenant's data.
    ///   2. Clear in-memory @Published arrays so the UI doesn't briefly
    ///      show outgoing-tenant data after the swap.
    ///   3. Update `currentCompanyID`.
    ///   4. Re-attach `LocalPendingStore` to the new tenant directory.
    ///   5. Kick a full pull. `pullAll()` will repopulate every
    ///      @Published array for the new tenant.
    ///
    /// While the pull is in flight `isSyncing` is true and the UI can
    /// show its standard loading state; once it returns the user lands
    /// in the new company's home tab.
    @MainActor
    func switchToCompany(_ companyID: UUID) async {
        guard companyID != currentCompanyID else { return }

        // Step 1: persist outgoing-tenant pending writes BEFORE we
        // swap the tenant ID. Otherwise the buffered writes would
        // land in the new tenant's directory.
        saveToDiskImmediately()

        // Step 2: wipe in-memory caches. The pull replaces them with
        // the new tenant's rows; until then the UI shows empty lists
        // (better than showing stale outgoing-tenant data).
        wipeInMemoryDataForCompanySwitch()

        // Step 3: swap the tenant ID.
        self.currentCompanyID = companyID

        // Step 4: re-attach local persistence + replay any pending
        // writes the new tenant had buffered from a prior session.
        bindLocalPersistence(companyID: companyID)

        // Step 5: re-pull everything for the new tenant. The pullAll
        // call here runs against the new currentCompanyID since every
        // pull filter reads that field at the top of the function.
        guard let userID = currentUser?.id else { return }
        await SyncEngine.shared.pullAll(for: userID, role: currentUserRole)

        // Refresh the membership flags so the switcher shows the new
        // active row when the user opens it next.
        await pullCompanyMemberships()
    }

    /// Wipes all in-memory tenant-scoped data so the UI doesn't show
    /// outgoing-tenant rows during the swap window. Pending writes
    /// were already persisted in step 1; this only clears the
    /// @Published cache.
    @MainActor
    private func wipeInMemoryDataForCompanySwitch() {
        projects = []
        employees = []
        crews = []
        scheduleEntries = []
        timesheetEntries = []
        invoices = []
        estimates = []
        quotes = []
        materialSales = []
        contracts = []
        rfis = []
        changeOrders = []
        materialRequests = []
        purchaseOrders = []
        suppliers = []
        subcontractors = []
        subContracts = []
        clients = []
        crmContacts = []
        crmOpportunities = []
        crmTasks = []
        crmActivities = []
        incidents = []
        equipment = []
        formTemplates = []
        formSubmissions = []
        inventoryItems = []
        stockLocations = []
        inventoryStockLevels = []
        inventoryTransfers = []
    }
}

// MARK: - Company Switcher Sheet

struct CompanySwitcherSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    @State private var isLoading = false
    @State private var switchingTo: UUID? = nil
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            Group {
                if store.companyMemberships.isEmpty {
                    emptyOrLoadingState
                } else {
                    membershipList
                }
            }
            .navigationTitle("Switch Company")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                isLoading = true
                await store.pullCompanyMemberships()
                isLoading = false
            }
        }
    }

    private var membershipList: some View {
        List {
            Section {
                ForEach(store.companyMemberships) { membership in
                    Button {
                        Task { await switchTo(membership) }
                    } label: {
                        membershipRow(membership)
                    }
                    .buttonStyle(.plain)
                    .disabled(switchingTo != nil)
                }
            } footer: {
                if store.companyMemberships.count == 1 {
                    Text("You belong to a single company. Multi-tenant switching unlocks once your account is added to additional tenants.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let err = errorMessage {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.subheadline)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func membershipRow(_ membership: CompanyMembership) -> some View {
        let isActive = membership.id == store.currentCompanyID
        let isSwitching = switchingTo == membership.id
        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isActive ? Color.blue.opacity(0.15) : Color(.systemGray5))
                    .frame(width: 36, height: 36)
                Image(systemName: "building.2.fill")
                    .foregroundColor(isActive ? .blue : .secondary)
                    .font(.system(size: 14))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(membership.displayName)
                    .font(.subheadline).bold()
                    .foregroundColor(.primary)
                Text(membership.id.uuidString.prefix(8) + "…")
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }
            Spacer()
            if isSwitching {
                ProgressView().controlSize(.small)
            } else if isActive {
                Label("Current", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundColor(.blue)
            } else {
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.caption2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var emptyOrLoadingState: some View {
        VStack(spacing: 16) {
            if isLoading {
                ProgressView()
                Text("Loading your companies…")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: "building.2")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text("No companies available")
                    .font(.headline)
                Text("Your account isn't linked to any companies, or the request failed. Pull to refresh from the home screen and try again.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func switchTo(_ membership: CompanyMembership) async {
        guard membership.id != store.currentCompanyID else {
            dismiss()
            return
        }
        switchingTo = membership.id
        errorMessage = nil
        await store.switchToCompany(membership.id)
        switchingTo = nil
        dismiss()
    }
}
