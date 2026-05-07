// ClientViews.swift
// AskiCommand – Client Database
// NEW FILE — master client records that feed estimates, quotes, and projects

import SwiftUI
import Combine

// MARK: - Client Model

struct Client: Identifiable, Codable, Equatable {
    var id: UUID = UUID()

    // Identity
    var name: String                        // Company name
    var code: String?                       // Short client code e.g. "HBM"

    // Primary Contact
    var contactName: String?
    var contactTitle: String?
    var contactEmail: String?
    var contactPhone: String?

    // Billing
    var billingAddress: String?
    var billingCity: String?
    var billingProvince: String?
    var billingPostal: String?

    // Sites (a client can have multiple sites)
    var sites: [ClientSite] = []

    // Commercial
    var defaultPaymentTerms: String?        // Overrides company default if set
    var taxExempt: Bool = false
    var notes: String?

    // Status
    var isActive:   Bool    = true
    var createdAt:  Date    = Date()
    var syncStatus: SyncStatus = .local
    var companyID:  UUID?   = nil
    var isDeleted:  Bool    = false
    var deletedAt:  Date?   = nil
    var deletedBy:  String? = nil

    // MARK: Sample data tracking
    // Populated only by SampleDataSeeder; immutable post-insert via DB trigger.
    var isSampleData:           Bool      = false
    var sampleDataBatchID:      UUID?     = nil
    var sampleDataSeedVersion:  String?   = nil
    var sampleDataCreatedAt:    Date?     = nil
    var sampleDataCreatedBy:    UUID?     = nil

    // Computed
    var fullBillingAddress: String {
        [billingAddress, billingCity, billingProvince, billingPostal]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    var initials: String {
        let words = name.components(separatedBy: " ")
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}

// MARK: - Client Site

struct ClientSite: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String                        // e.g. "Leduc Plant", "Fort McMurray Site 2"
    var address: String
    var city: String?
    var province: String?
    var postalCode: String?
    var accessNotes: String?                // Gate codes, parking, security check-in
    var safetyNotes: String?               // PPE requirements, H2S zones, site hazards
    var logisticsNotes: String?            // Parking, staging area, laydown yard
    var isDefault: Bool = false

    var formattedAddress: String {
        [address, city, province, postalCode]
            .compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

// MARK: - Client Store Extension

extension AppStore {

    func upsertClient(_ client: Client) {
        var updated = client
        // BUG FIX: this guard previously read
        //   `if updated.syncStatus != .synced { updated.syncStatus = .pending }`
        // The intent was probably "preserve .synced so we don't
        // double-push a row we just pulled". The side effect was a
        // silent data-loss bug: any LOCAL edit to a row that came
        // back from the server (i.e. status .synced) kept its
        // .synced status, and `pushPendingClients` (which filters
        // for .pending/.local) skipped it. The edit lived in
        // memory until the next pull overwrote it with the server's
        // unchanged version. This is why every client had
        // `sites_json = "[]"` — site additions never reached the
        // server.
        // Correct behavior: `upsertClient` is the iOS-side write
        // path. Calling it MEANS the row has been modified locally
        // and needs to push. Always mark .pending. The pull path
        // uses `upsertClientSynced` which deliberately leaves the
        // status alone.
        updated.syncStatus = .pending
        if let index = clients.firstIndex(where: { $0.id == updated.id }) {
            clients[index] = updated
        } else {
            clients.append(updated)
        }
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPendingClients() }
        // Mirror into the system Spotlight index.
        SpotlightService.shared.upsert(client: updated)
    }

    enum ClientDeletionError: LocalizedError {
        case notPermitted
        case notFound
        case hasDependents(String)

        var errorDescription: String? {
            switch self {
            case .notPermitted:
                return "You don't have permission to delete this client."
            case .notFound:
                return "Client not found."
            case .hasDependents(let summary):
                return "This client still has \(summary). Archive or reassign those records before deleting."
            }
        }
    }

    /// Counts active (non-deleted) records that reference a client,
    /// either directly or via the opportunity / project chain.
    ///
    /// PHASE-1 STEP 6 (alignment with RM6 trigger): the trigger blocks
    /// hard-delete when ANY of 20 dependent tables has a non-deleted
    /// row pointing at this client. This Swift function mirrors that
    /// set as closely as the iOS data model allows. Any divergence
    /// here → trigger fires server-side and the user gets an error
    /// from Postgres. The goal is to NEVER hit the trigger because
    /// the UI already blocked the delete.
    func clientDependents(for clientID: UUID) -> [String] {
        var parts: [String] = []

        // Direct FK to clients.id (7 tables).
        let opps = crmOpportunities.filter { $0.clientID == clientID && !$0.isDeleted }.count
        if opps > 0 { parts.append("\(opps) opportunit\(opps == 1 ? "y" : "ies")") }
        let qs = quotes.filter { $0.clientID == clientID && !$0.isDeleted }.count
        if qs > 0 { parts.append("\(qs) quote\(qs == 1 ? "" : "s")") }
        let sales = materialSales.filter { $0.clientID == clientID && !$0.isDeleted }.count
        if sales > 0 { parts.append("\(sales) material sale\(sales == 1 ? "" : "s")") }
        let contacts = crmContacts.filter { $0.clientID == clientID && !$0.isDeleted }.count
        if contacts > 0 { parts.append("\(contacts) contact\(contacts == 1 ? "" : "s")") }
        let tasks = crmTasks.filter { $0.clientID == clientID && !$0.isDeleted }.count
        if tasks > 0 { parts.append("\(tasks) CRM task\(tasks == 1 ? "" : "s")") }
        let acts = crmActivities.filter { $0.clientID == clientID && !$0.isDeleted }.count
        if acts > 0 { parts.append("\(acts) CRM activit\(acts == 1 ? "y" : "ies")") }
        // ClientPricing has no isDeleted field on iOS today — count
        // every row keyed to this client.
        let pricings = clientPricings.filter { $0.clientID == clientID }.count
        if pricings > 0 { parts.append("\(pricings) pricing rule\(pricings == 1 ? "" : "s")") }

        // Reachable via opportunity (cascade-deleted from client server-side
        // but historical record exists on iOS today).
        let projs = projects.filter {
            !$0.isDeleted && $0.clientID == clientID
        }
        if !projs.isEmpty { parts.append("\(projs.count) project\(projs.count == 1 ? "" : "s")") }
        let projIDs = Set(projs.map { $0.id })

        let ests = estimates.filter {
            !$0.isDeleted && $0.clientID == clientID
        }.count
        if ests > 0 { parts.append("\(ests) estimate\(ests == 1 ? "" : "s")") }

        // Invoice has no opportunityID on iOS — match via clientID OR
        // an Optional projectID resolving into our project set. The
        // server-side trigger (RM6) covers the opportunity path
        // exhaustively; the UI is the first line of defense.
        let invs = invoices.filter {
            guard !$0.isDeleted else { return false }
            if $0.clientID == clientID { return true }
            if let pid = $0.projectID, projIDs.contains(pid) { return true }
            return false
        }.count
        if invs > 0 { parts.append("\(invs) invoice\(invs == 1 ? "" : "s")") }

        // ChangeOrder.projectID is non-optional — direct contains.
        let cos = changeOrders.filter {
            !$0.isDeleted && projIDs.contains($0.projectID)
        }.count
        if cos > 0 { parts.append("\(cos) change order\(cos == 1 ? "" : "s")") }

        // PurchaseOrder has no opportunityID on iOS — match via Optional projectID.
        let pos = purchaseOrders.filter {
            guard !$0.isDeleted else { return false }
            if let pid = $0.projectID, projIDs.contains(pid) { return true }
            return false
        }.count
        if pos > 0 { parts.append("\(pos) purchase order\(pos == 1 ? "" : "s")") }

        // MaterialRequest has no opportunityID on iOS — match via Optional projectID.
        let mreqs = materialRequests.filter {
            guard !$0.isDeleted else { return false }
            if let pid = $0.projectID, projIDs.contains(pid) { return true }
            return false
        }.count
        if mreqs > 0 { parts.append("\(mreqs) material request\(mreqs == 1 ? "" : "s")") }

        // Deeper field history reachable via projects.
        // TimesheetEntry.projectID + ScheduleEntry.projectID are
        // non-optional UUID on iOS even though the DB FK is SET NULL —
        // the iOS model uses the empty-UUID sentinel. Direct contains.
        let ts = timesheetEntries.filter {
            !$0.isDeleted && projIDs.contains($0.projectID)
        }.count
        if ts > 0 { parts.append("\(ts) timesheet entr\(ts == 1 ? "y" : "ies")") }

        let djr = formSubmissions.filter {
            guard !$0.isDeleted else { return false }
            if let pid = $0.projectID, projIDs.contains(pid) { return true }
            return false
        }.count
        if djr > 0 { parts.append("\(djr) form submission\(djr == 1 ? "" : "s")") }

        let scheds = scheduleEntries.filter {
            !$0.isDeleted && projIDs.contains($0.projectID)
        }.count
        if scheds > 0 { parts.append("\(scheds) schedule entr\(scheds == 1 ? "y" : "ies")") }

        let incs = incidents.filter {
            guard !$0.isDeleted else { return false }
            if let pid = $0.projectID, projIDs.contains(pid) { return true }
            return false
        }.count
        if incs > 0 { parts.append("\(incs) incident\(incs == 1 ? "" : "s")") }

        let rs = rfis.filter {
            !$0.isDeleted && projIDs.contains($0.projectID)
        }.count
        if rs > 0 { parts.append("\(rs) RFI\(rs == 1 ? "" : "s")") }

        return parts
    }

    /// Soft-delete a client. Always allowed for `office_admin+`
    /// regardless of dependents — the row is hidden from active lists
    /// but commercial history is preserved. Use this as the default
    /// path. PHASE-1 STEP 6.
    @discardableResult
    func softDeleteClient(_ client: Client) -> Result<Void, ClientDeletionError> {
        guard requireRole([.officeAdmin, .manager, .executive, .owner],
                          action: "soft_delete_client") else {
            return .failure(.notPermitted)
        }
        guard let idx = clients.firstIndex(where: { $0.id == client.id }) else {
            return .failure(.notFound)
        }
        var deleted = clients[idx]
        deleted.isDeleted  = true
        deleted.deletedAt  = Date()
        deleted.deletedBy  = currentUser?.fullName ?? ""
        deleted.syncStatus = .pending
        clients[idx] = deleted
        objectWillChange.send()
        saveToDisk()
        Task { await SyncEngine.shared.pushPendingClients() }
        return .success(())
    }

    /// Hard-delete (existing path, kept name for back-compat). Tightened
    /// in Phase 1 Step 6 to executive/owner only AND only when zero
    /// dependents exist. The DB trigger RM6 is the server-side belt-
    /// and-braces guard against any UI bypass.
    ///
    /// Matrix C.2 rule: "Hard-delete Client (with history) → blocked
    /// for ALL authenticated users including owner. Hard-delete Client
    /// (no history) → executive/owner only."
    @discardableResult
    func deleteClient(_ client: Client) -> Result<Void, ClientDeletionError> {
        guard requireRole([.executive, .owner], action: "delete_client") else {
            return .failure(.notPermitted)
        }
        guard let idx = clients.firstIndex(where: { $0.id == client.id }) else {
            return .failure(.notFound)
        }
        let deps = clientDependents(for: client.id)
        if !deps.isEmpty {
            return .failure(.hasDependents(deps.joined(separator: ", ")))
        }
        var deleted = clients[idx]
        deleted.isDeleted  = true
        deleted.deletedAt  = Date()
        deleted.deletedBy  = currentUser?.fullName ?? ""
        deleted.syncStatus = .pending
        clients[idx] = deleted
        objectWillChange.send()
        saveToDisk()
        Task { await SyncEngine.shared.pushPendingClients() }
        return .success(())
    }

    func client(id: UUID) -> Client? {
        clients.first { $0.id == id }
    }

    func upsertClientSynced(_ client: Client) {
        if let index = clients.firstIndex(where: { $0.id == client.id }) {
            clients[index] = client
        } else {
            clients.append(client)
        }
        objectWillChange.send()
    }
}

// MARK: - Client List View

struct ClientListView: View {
    @EnvironmentObject var store: AppStore
    @State private var searchText = ""
    @State private var showCreate = false
    @StateObject private var pagination = PaginationState(pageSize: 25)

    private var filtered: [Client] {
        store.clients
            .filter { $0.isActive }
            .filter {
                searchText.isEmpty ||
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                ($0.contactName ?? "").localizedCaseInsensitiveContains(searchText)
            }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "building.2")
                            .font(.system(size: 52))
                            .foregroundColor(.secondary)
                        Text("No clients yet.")
                            .font(.headline)
                        Text("Add your first client to start estimating.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Add Client") { showCreate = true }
                            .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                } else {
                    List {
                        ForEach(Array(filtered.prefix(pagination.displayLimit))) { client in
                            NavigationLink {
                                ClientDetailView(client: client)
                            } label: {
                                ClientListRow(client: client)
                            }
                        }
                        LoadMoreFooter(
                            showing: min(pagination.displayLimit, filtered.count),
                            total:   filtered.count,
                            onLoad:  { pagination.loadMore() }
                        )
                    }
                    .listStyle(.plain)
                    .onChange(of: searchText) { pagination.reset() }
                }
            }
            .searchable(text: $searchText, prompt: "Search clients or contacts")
            .refreshable { await store.refreshAll() }
            .navigationTitle("Clients")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showCreate = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add client")
                }
            }
            .sheet(isPresented: $showCreate) {
                ClientCreateEditView()
            }
        }
    }
}

// MARK: - Client List Row

struct ClientListRow: View {
    let client: Client

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            Circle()
                .fill(Color.blue.opacity(0.12))
                .frame(width: 44, height: 44)
                .overlay(
                    Text(client.initials)
                        .font(.headline)
                        .foregroundColor(.blue)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(client.name).font(.headline)
                if let contact = client.contactName {
                    Text(contact)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                if !client.fullBillingAddress.isEmpty {
                    Label(client.fullBillingAddress, systemImage: "mappin")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let code = client.code {
                Text(code)
                    .font(.caption)
                    .bold()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.blue.opacity(0.1))
                    .foregroundColor(.blue)
                    .cornerRadius(6)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Client Detail View

struct ClientDetailView: View {
    let client: Client
    @EnvironmentObject var store: AppStore
    @State private var showEdit              = false
    @State private var showNewEstimate       = false
    @State private var showAddContact        = false
    @State private var showCommercialIntake  = false
    @State private var selectedSite: ClientSite? = nil

    // Contacts for this client
    private var contacts: [CRMContact] {
        store.crmContacts
            .filter { $0.clientID == client.id }
            .sorted { ($0.isPrimary ? 0 : 1) < ($1.isPrimary ? 0 : 1) }
    }

    // Jobs linked to this client
    private var activeProjects: [Project] {
        store.projects.filter { $0.clientName == client.name && $0.status == .active }
    }

    // Estimates linked to this client
    private var clientEstimates: [Estimate] {
        store.estimates
            .filter { $0.clientID == client.id }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // ── Header Card ───────────────────────────────────────
                VStack(spacing: 12) {
                    Circle()
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 72, height: 72)
                        .overlay(
                            Text(client.initials)
                                .font(.title).bold()
                                .foregroundColor(.blue)
                        )
                    Text(client.name).font(.title2).bold()
                    if let code = client.code {
                        Text(code).font(.subheadline).foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(16)
                .padding(.horizontal)

                // ── Quick Stats ───────────────────────────────────────
                HStack(spacing: 12) {
                    MiniKPICard(value: "\(contacts.count)",      label: "Contacts", icon: "person.2.fill")
                    MiniKPICard(value: "\(client.sites.count)",  label: "Sites",    icon: "mappin.circle.fill")
                    MiniKPICard(value: "\(activeProjects.count)",label: "Active Jobs", icon: "folder.fill")
                }
                .padding(.horizontal)

                // ── Action Buttons ────────────────────────────────────
                HStack(spacing: 10) {
                    Button {
                        showCommercialIntake = true
                    } label: {
                        Label("New Work", systemImage: "plus.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    NavigationLink {
                        SiteRevenueView(clientID: client.id)
                            .environmentObject(store)
                    } label: {
                        Label("Revenue", systemImage: "chart.bar.fill")
                            .font(.subheadline).bold()
                            .padding()
                            .background(Color.green.opacity(0.15))
                            .foregroundColor(.green)
                            .cornerRadius(12)
                    }
                }
                .padding(.horizontal)

                // ── Contacts ─────────────────────────────────────────
                SectionHeader(title: "Contacts", count: contacts.count, actionTitle: "Add") {
                    showAddContact = true
                }
                if contacts.isEmpty {
                    EmptyCard(message: "No contacts yet. Add a decision maker or site contact.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(contacts) { contact in
                            ClientContactRow(contact: contact)
                            if contact.id != contacts.last?.id {
                                Divider().padding(.leading, 56)
                            }
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)
                }

                // ── Billing Address ───────────────────────────────────
                if !client.fullBillingAddress.isEmpty {
                    SectionHeader(title: "Billing Address")
                    Text(client.fullBillingAddress)
                        .font(.subheadline).foregroundColor(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)
                }

                // ── Sites ─────────────────────────────────────────────
                SectionHeader(title: "Sites", count: client.sites.count)
                if client.sites.isEmpty {
                    EmptyCard(message: "No sites added yet. Sites are required for estimates.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(client.sites) { site in
                            Button { selectedSite = site } label: {
                                ClientSiteRow(site: site, contacts: contacts)
                            }
                            .buttonStyle(.plain)
                            if site.id != client.sites.last?.id {
                                Divider().padding(.leading)
                            }
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)
                }

                // ── Recent Estimates ──────────────────────────────────
                if !clientEstimates.isEmpty {
                    SectionHeader(title: "Estimates", count: clientEstimates.count)
                    VStack(spacing: 0) {
                        ForEach(clientEstimates.prefix(5)) { estimate in
                            ClientEstimateRow(estimate: estimate, client: client, store: store)
                            if estimate.id != clientEstimates.prefix(5).last?.id {
                                Divider().padding(.leading)
                            }
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)
                }

                // ── Active Projects ───────────────────────────────────
                if !activeProjects.isEmpty {
                    SectionHeader(title: "Active Projects", count: activeProjects.count)
                    ForEach(activeProjects) { project in
                        NavigationLink {
                            ProjectDetailView(project: project)
                        } label: {
                            ProjectSummaryRow(project: project).padding(.horizontal)
                        }
                    }
                }

                // ── Notes ─────────────────────────────────────────────
                if let notes = client.notes, !notes.isEmpty {
                    SectionHeader(title: "Notes")
                    Text(notes)
                        .font(.subheadline).foregroundColor(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)
                }

                Spacer(minLength: 32)
            }
            .padding(.top)
        }
        .navigationTitle(client.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Edit") { showEdit = true }
            }
        }
        .sheet(isPresented: $showEdit) {
            ClientCreateEditView(existing: client)
        }
        .sheet(isPresented: $showNewEstimate) {
            EstimateCreateView(preselectedClientID: client.id)
        }
        .sheet(isPresented: $showCommercialIntake) {
            CommercialIntakeView(
                prefillContext: CommercialContext.from(client: client)
            )
            .environmentObject(store)
        }
        .sheet(isPresented: $showAddContact) {
            AddCRMContactSheet(clientID: client.id)
        }
        .sheet(item: $selectedSite) { site in
            SiteDetailView(site: site, client: client)
        }
    }
}

// MARK: - Client Contact Row

struct ClientContactRow: View {
    @EnvironmentObject var store: AppStore
    let contact: CRMContact
    /// Long-press → context menu → Delete → confirmation. Same
    /// two-step gate as the CRM-side ContactRowView. Hidden for
    /// roles that lack canDeleteCRM.
    @State private var showDeleteConfirm: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            ZStack {
                Circle()
                    .fill(contact.role.color.opacity(0.15))
                    .frame(width: 40, height: 40)
                Text(contact.initials)
                    .font(.subheadline).bold()
                    .foregroundColor(contact.role.color)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(contact.fullName).font(.subheadline).bold()
                    if contact.isPrimary {
                        Text("Primary")
                            .font(.caption2).bold()
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.blue.opacity(0.12))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: contact.role.icon)
                        .font(.caption2)
                        .foregroundColor(contact.role.color)
                    Text(contact.role.label)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if !contact.title.isEmpty {
                        Text("· \(contact.title)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Quick actions
            VStack(alignment: .trailing, spacing: 4) {
                if !contact.phone.isEmpty {
                    Link(destination: URL(string: "tel:\(contact.phone)")!) {
                        Image(systemName: "phone.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                if !contact.email.isEmpty {
                    Link(destination: URL(string: "mailto:\(contact.email)")!) {
                        Image(systemName: "envelope.fill")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
            }
        }
        .padding()
        .contentShape(Rectangle())
        .contextMenu {
            if store.currentUserRole.canDeleteCRM {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete Contact", systemImage: "trash")
                }
            }
        }
        .confirmationDialog(
            "Delete \(contact.fullName)?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                store.deleteCRMContact(contact)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This contact will be hidden from the CRM. Activity history is preserved.")
        }
    }
}

// MARK: - Client Site Row

struct ClientSiteRow: View {
    let site: ClientSite
    let contacts: [CRMContact]

    private var siteContacts: [CRMContact] {
        contacts.filter { $0.siteID == site.id }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(.title2)
                .foregroundColor(.orange)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(site.name).font(.subheadline).bold()
                    if site.isDefault {
                        Text("Default")
                            .font(.caption2).bold()
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.green.opacity(0.12))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                    }
                }
                Text(site.formattedAddress.isEmpty ? site.address : site.formattedAddress)
                    .font(.caption).foregroundColor(.secondary)
                if !siteContacts.isEmpty {
                    Text(siteContacts.map { $0.fullName }.joined(separator: ", "))
                        .font(.caption2).foregroundColor(.blue)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}

// MARK: - Client Estimate Row

struct ClientEstimateRow: View {
    let estimate: Estimate
    let client: Client
    let store: AppStore

    private var siteName: String {
        guard let siteID = estimate.siteID else { return "" }
        return client.sites.first(where: { $0.id == siteID })?.name ?? ""
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(estimate.jobNumber).font(.caption).foregroundColor(.secondary)
                Text(estimate.name).font(.subheadline).bold().lineLimit(1)
                if !siteName.isEmpty {
                    Label(siteName, systemImage: "mappin")
                        .font(.caption).foregroundColor(.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                EstimateStatusBadge(status: estimate.status)
                Text(estimate.totalEstimated, format: .currency(code: "CAD"))
                    .font(.subheadline).bold()
            }
        }
        .padding()
    }
}

// MARK: - Add CRM Contact Sheet (inline quick-add)

struct AddCRMContactSheet: View {
    let clientID: UUID
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    @State private var firstName  = ""
    @State private var lastName   = ""
    @State private var title      = ""
    @State private var phone      = ""
    @State private var email      = ""
    @State private var role: ContactRole = .general
    @State private var isPrimary  = false
    @State private var notes      = ""
    @State private var selectedSiteID: UUID? = nil

    private var client: Client? { store.client(id: clientID) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Contact Info *") {
                    TextField("First Name", text: $firstName)
                    TextField("Last Name", text: $lastName)
                    TextField("Job Title", text: $title)
                    TextField("Phone", text: $phone).keyboardType(.phonePad)
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                }

                Section("Role") {
                    Picker("Role", selection: $role) {
                        ForEach(ContactRole.allCases) { r in
                            Label(r.label, systemImage: r.icon).tag(r)
                        }
                    }
                    .pickerStyle(.menu)
                    Toggle("Primary Contact", isOn: $isPrimary)
                }

                if let sites = client?.sites, !sites.isEmpty {
                    Section("Assign to Site (Optional)") {
                        Picker("Site", selection: $selectedSiteID) {
                            Text("No specific site").tag(UUID?.none)
                            ForEach(sites) { site in
                                Text(site.name).tag(UUID?.some(site.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Section("Notes") {
                    TextEditor(text: $notes).frame(minHeight: 60)
                }
            }
            .navigationTitle("Add Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }
                        .bold()
                        .disabled(firstName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func save() {
        var contact = CRMContact(clientID: clientID)
        contact.firstName  = firstName.trimmingCharacters(in: .whitespaces)
        contact.lastName   = lastName.trimmingCharacters(in: .whitespaces)
        contact.title      = title
        contact.phone      = phone
        contact.email      = email
        contact.role       = role
        contact.isPrimary  = isPrimary
        contact.siteID     = selectedSiteID
        contact.notes      = notes
        store.upsertCRMContact(contact)
        dismiss()
    }
}

// MARK: - Client Info Row

struct ClientInfoRow: View {
    let label: String
    let value: String
    var isLink: Bool = false
    var linkURL: String = ""

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            if isLink {
                Link(value, destination: URL(string: linkURL) ?? URL(string: "https://askicommand.com")!)
                    .font(.subheadline)
                    .foregroundColor(.blue)
            } else {
                Text(value)
                    .font(.subheadline)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding()
    }
}

// MARK: - Client Create / Edit View

struct ClientCreateEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    var existing: Client? = nil

    @State private var name = ""
    @State private var code = ""
    @State private var contactName = ""
    @State private var contactTitle = ""
    @State private var contactEmail = ""
    @State private var contactPhone = ""
    @State private var billingAddress = ""
    @State private var billingCity = ""
    @State private var billingProvince = ""
    @State private var billingPostal = ""
    @State private var notes = ""
    @State private var taxExempt = false
    @State private var sites: [ClientSite] = []
    @State private var showAddSite = false
    @State private var showValidationError = false
    @State private var validationMessage = ""

    @State private var showDeletionBlocked = false
    @State private var deletionBlockedReason = ""
    // Phase 1 Step 6 — soft-delete confirmation flow.
    @State private var showSoftDeleteConfirm = false
    @State private var showHardDeleteConfirm = false
    @State private var softDeleteFailedReason: String? = nil

    private var isEditing: Bool { existing != nil }

    var body: some View {
        NavigationStack {
            Form {

                // Company
                Section("Company *") {
                    TextField("Client / Company Name", text: $name)
                    HStack {
                        Text("Client Code")
                        Spacer()
                        TextField("e.g. HBM", text: $code)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.characters)
                            .frame(width: 80)
                    }
                }

                // Contact
                Section("Primary Contact") {
                    TextField("Contact Name", text: $contactName)
                    TextField("Title / Role", text: $contactTitle)
                    TextField("Email", text: $contactEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                    TextField("Phone", text: $contactPhone)
                        .keyboardType(.phonePad)
                }

                // Billing
                Section("Billing Address") {
                    AddressSearchRow(
                        label:      "Billing Address",
                        street:     $billingAddress,
                        city:       $billingCity,
                        province:   $billingProvince,
                        postalCode: $billingPostal
                    )
                    if !billingAddress.isEmpty {
                        TextField("Street", text: $billingAddress)
                    }
                    TextField("City", text: $billingCity)
                    TextField("Province / State", text: $billingProvince)
                    TextField("Postal / ZIP Code", text: $billingPostal)
                }

                // Sites
                Section {
                    Button {
                        showAddSite = true
                    } label: {
                        Label("Add Site", systemImage: "plus.circle")
                            .foregroundColor(.blue)
                    }
                    ForEach(sites) { site in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(site.name).font(.subheadline).bold()
                                if site.isDefault {
                                    Text("Default")
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.15))
                                        .foregroundColor(.green)
                                        .cornerRadius(4)
                                }
                            }
                            Text(site.address)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { indices in
                        sites.remove(atOffsets: indices)
                    }
                } header: {
                    Text("Sites (\(sites.count))")
                }

                // Other
                Section("Other") {
                    Toggle("Tax Exempt", isOn: $taxExempt)
                    TextEditor(text: $notes)
                        .frame(minHeight: 60)
                }

                if isEditing, let c = existing {
                    clientDeletionSection(for: c)
                }
            }
            .navigationTitle(isEditing ? "Edit Client" : "New Client")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }.bold()
                }
            }
            .alert("Missing Info", isPresented: $showValidationError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationMessage)
            }
            .alert("Cannot Delete Client", isPresented: $showDeletionBlocked) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deletionBlockedReason)
            }
            // Phase 1 Step 6: soft-delete confirmation. ANY office_admin+
            // can mark a client inactive — history is preserved.
            .confirmationDialog(
                softDeleteConfirmTitle,
                isPresented: $showSoftDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Mark Inactive", role: .destructive) {
                    if let c = existing {
                        switch store.softDeleteClient(c) {
                        case .success:
                            dismiss()
                        case .failure(let err):
                            softDeleteFailedReason = err.errorDescription ?? "Could not mark inactive."
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(softDeleteConfirmMessage)
            }
            // Phase 1 Step 6: hard-delete confirmation. Only fires when
            // dependents are zero (UI computes this before showing the
            // button) AND caller is executive/owner. RM6 trigger is the
            // server-side belt-and-braces guard.
            .confirmationDialog(
                "Permanently delete this client?",
                isPresented: $showHardDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Permanently Delete", role: .destructive) {
                    if let c = existing {
                        switch store.deleteClient(c) {
                        case .success:
                            dismiss()
                        case .failure(let err):
                            deletionBlockedReason = err.errorDescription ?? "Cannot delete client."
                            showDeletionBlocked = true
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This client has no commercial history. Hard-delete cannot be undone.")
            }
            .alert("Soft-delete Failed", isPresented: Binding(
                get: { softDeleteFailedReason != nil },
                set: { if !$0 { softDeleteFailedReason = nil } }
            )) {
                Button("OK", role: .cancel) { softDeleteFailedReason = nil }
            } message: {
                Text(softDeleteFailedReason ?? "")
            }
            .sheet(isPresented: $showAddSite) {
                AddClientSiteSheet { newSite in
                    if sites.isEmpty {
                        var defaultSite = newSite
                        defaultSite.isDefault = true
                        sites.append(defaultSite)
                    } else {
                        sites.append(newSite)
                    }
                }
            }
            .onAppear { populate() }
        }
    }

    // MARK: - Phase 1 Step 6: client deletion section
    //
    // Matrix C.2:
    //   • Soft-delete (Mark Inactive)         — office_admin / manager / executive / owner
    //   • Hard-delete (no history)            — executive / owner only
    //   • Hard-delete (with history)          — blocked for everyone (DB trigger RM6)
    // The hard-delete button is hidden unless BOTH conditions are true:
    //   1. Caller role is executive or owner
    //   2. clientDependents(for:) returns zero rows
    // Otherwise only the soft-delete button is shown — the safer default
    // and the only path normal users should ever take.

    @ViewBuilder
    private func clientDeletionSection(for c: Client) -> some View {
        let deps = store.clientDependents(for: c.id)
        let canSoftDelete = store.currentUserRole.canSoftDeleteClient
        let canHardDelete = store.currentUserRole.canHardDeleteClientWithoutHistory && deps.isEmpty

        Section {
            if canSoftDelete {
                Button(role: .destructive) {
                    showSoftDeleteConfirm = true
                } label: {
                    Label("Mark Inactive", systemImage: "archivebox")
                }
            }
            if canHardDelete {
                Button(role: .destructive) {
                    showHardDeleteConfirm = true
                } label: {
                    Label("Permanently Delete", systemImage: "trash.fill")
                }
            } else if !deps.isEmpty {
                // Surface why hard-delete isn't available even when the
                // user has the role to use it. Soft-delete remains.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Permanent delete blocked — has history:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(deps.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Danger Zone")
        } footer: {
            if canSoftDelete && !canHardDelete {
                Text("Mark Inactive hides the client from active lists but preserves all commercial history. Permanent deletion requires zero linked records and Executive or Owner role.")
                    .font(.caption2)
            }
        }
    }

    /// Title shown in the soft-delete confirmation dialog. Adapts to
    /// reflect whether the client carries history (so the user knows
    /// soft-delete is the only path).
    private var softDeleteConfirmTitle: String {
        guard let c = existing else { return "Mark client inactive?" }
        let deps = store.clientDependents(for: c.id)
        return deps.isEmpty
            ? "Mark client inactive?"
            : "Mark inactive (history preserved)?"
    }

    /// Detail message in the soft-delete confirmation dialog. Lists the
    /// dependent record counts so the user understands what's being
    /// preserved.
    private var softDeleteConfirmMessage: String {
        guard let c = existing else {
            return "The client will be hidden from active lists."
        }
        let deps = store.clientDependents(for: c.id)
        if deps.isEmpty {
            return "The client will be hidden from active lists. You can restore it later from the archived list."
        }
        return "Linked history will stay attached: " + deps.joined(separator: ", ") + ". The client will be hidden from active lists; nothing is deleted."
    }

    private func populate() {
        guard let c = existing else { return }
        name            = c.name
        code            = c.code ?? ""
        contactName     = c.contactName ?? ""
        contactTitle    = c.contactTitle ?? ""
        contactEmail    = c.contactEmail ?? ""
        contactPhone    = c.contactPhone ?? ""
        billingAddress  = c.billingAddress ?? ""
        billingCity     = c.billingCity ?? ""
        billingProvince = c.billingProvince ?? ""
        billingPostal   = c.billingPostal ?? ""
        notes           = c.notes ?? ""
        taxExempt       = c.taxExempt
        sites           = c.sites
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            validationMessage = "Client name is required."
            showValidationError = true
            return
        }

        // Phase-2 audit closeout: route NEW client creation through
        // ClientFactory so tenant scope, sync status, and duplicate-
        // name guard are applied consistently. Edits keep using the
        // direct mutation path because the existing record already
        // has those invariants set.
        var client: Client
        if var existing = existing {
            existing.name = trimmedName
            client        = existing
        } else {
            do {
                client = try ClientFactory.make(
                    ClientFactory.Input(
                        name:                trimmedName,
                        contactName:         contactName.isEmpty ? nil : contactName,
                        contactEmail:        contactEmail.isEmpty ? nil : contactEmail,
                        contactPhone:        contactPhone.isEmpty ? nil : contactPhone,
                        billingAddress:      billingAddress.isEmpty ? nil : billingAddress,
                        billingCity:         billingCity.isEmpty ? nil : billingCity,
                        billingProvince:     billingProvince.isEmpty ? nil : billingProvince,
                        billingPostal:       billingPostal.isEmpty ? nil : billingPostal,
                        taxExempt:           taxExempt,
                        notes:               notes.isEmpty ? nil : notes
                    ),
                    store: store
                )
            } catch let err as FactoryError {
                validationMessage = err.userMessage
                showValidationError = true
                return
            } catch {
                validationMessage = error.localizedDescription
                showValidationError = true
                return
            }
        }

        // The remaining fields the factory doesn't yet take (code,
        // contactTitle, sites) get written directly on the returned
        // record. Edit path applies all of them.
        client.code            = code.isEmpty ? nil : code.uppercased()
        client.contactTitle    = contactTitle.isEmpty ? nil : contactTitle
        // Re-stamp the rest on the EDIT path (no-op on new since the
        // factory already wrote them).
        if existing != nil {
            client.contactName     = contactName.isEmpty ? nil : contactName
            client.contactEmail    = contactEmail.isEmpty ? nil : contactEmail
            client.contactPhone    = contactPhone.isEmpty ? nil : contactPhone
            client.billingAddress  = billingAddress.isEmpty ? nil : billingAddress
            client.billingCity     = billingCity.isEmpty ? nil : billingCity
            client.billingProvince = billingProvince.isEmpty ? nil : billingProvince
            client.billingPostal   = billingPostal.isEmpty ? nil : billingPostal
            client.notes           = notes.isEmpty ? nil : notes
            client.taxExempt       = taxExempt
        }
        client.sites = sites

        store.upsertClient(client)
        dismiss()
    }
}

// MARK: - Add Client Site Sheet

struct AddClientSiteSheet: View {
    let onAdd: (ClientSite) -> Void
    @Environment(\.dismiss) var dismiss

    @State private var siteName       = ""
    @State private var address        = ""
    @State private var city           = ""
    @State private var province       = ""
    @State private var postalCode     = ""
    @State private var accessNotes    = ""
    @State private var safetyNotes    = ""
    @State private var logisticsNotes = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Site Details *") {
                    TextField("Site Name (e.g. Leduc Plant)", text: $siteName)

                    AddressSearchRow(
                        label:      "Site Address",
                        street:     $address,
                        city:       $city,
                        province:   $province,
                        postalCode: $postalCode
                    )
                    if !address.isEmpty {
                        TextField("Street", text: $address)
                    }
                    TextField("City", text: $city)
                    TextField("Province", text: $province)
                    TextField("Postal / ZIP", text: $postalCode)
                }
                Section("Access Notes") {
                    TextField("Gate code, parking, security check-in…", text: $accessNotes)
                }
                Section("Safety Notes") {
                    TextField("PPE requirements, H2S zones, site hazards…", text: $safetyNotes)
                }
                Section("Logistics Notes") {
                    TextField("Parking, staging area, laydown yard…", text: $logisticsNotes)
                }
            }
            .navigationTitle("Add Site")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") {
                        let fullAddress = [address, city, province, postalCode]
                            .filter { !$0.isEmpty }
                            .joined(separator: ", ")
                        let site = ClientSite(
                            name:             siteName,
                            address:          fullAddress,
                            city:             city.isEmpty ? nil : city,
                            province:         province.isEmpty ? nil : province,
                            postalCode:       postalCode.isEmpty ? nil : postalCode,
                            accessNotes:      accessNotes.isEmpty ? nil : accessNotes,
                            safetyNotes:      safetyNotes.isEmpty ? nil : safetyNotes,
                            logisticsNotes:   logisticsNotes.isEmpty ? nil : logisticsNotes
                        )
                        onAdd(site)
                        dismiss()
                    }
                    .bold()
                    .disabled(siteName.isEmpty || address.isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Client Picker Sheet
// Used by EstimateCreateView to select a client

struct ClientPickerSheet: View {
    @EnvironmentObject var store: AppStore
    @Binding var selectedClientID: UUID?
    @Environment(\.dismiss) var dismiss
    @State private var searchText = ""
    @State private var showCreate = false

    private var filtered: [Client] {
        store.clients
            .filter { $0.isActive }
            .filter {
                searchText.isEmpty ||
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { client in
                    Button {
                        selectedClientID = client.id
                        dismiss()
                    } label: {
                        HStack {
                            Circle()
                                .fill(Color.blue.opacity(0.12))
                                .frame(width: 36, height: 36)
                                .overlay(
                                    Text(client.initials)
                                        .font(.subheadline)
                                        .foregroundColor(.blue)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(client.name).font(.subheadline).bold()
                                if let contact = client.contactName {
                                    Text(contact).font(.caption).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            if selectedClientID == client.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    .foregroundColor(.primary)
                }

                // Add new client inline
                Button {
                    showCreate = true
                } label: {
                    Label("Add New Client", systemImage: "plus.circle")
                        .foregroundColor(.blue)
                }
            }
            .searchable(text: $searchText, prompt: "Search clients")
            .navigationTitle("Select Client")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showCreate) {
                ClientCreateEditView()
            }
        }
    }
}

// MARK: - Sample-data tracking
extension Client: SampleDataTrackable {}
