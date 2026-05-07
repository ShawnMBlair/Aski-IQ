// CommercialIntakeView.swift
// Aski IQ — Commercial Intake Hub
//
// The single required entry point for all new commercial work.
// STEP 1: Select work type
// STEP 2: Select (or create) a client
// STEP 3: Route to the correct create view with CommercialContext pre-filled

import SwiftUI

// MARK: - Intake Step

private enum IntakeStep {
    case workType
    case clientSelect
}

// MARK: - Commercial Intake View

struct CommercialIntakeView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    /// Optional — pass a pre-filled context to skip steps (smart shortcuts).
    var prefillContext: CommercialContext? = nil

    @State private var step:    IntakeStep        = .workType
    @State private var context: CommercialContext = CommercialContext()
    @State private var clientSearch               = ""

    // Routing sheets
    @State private var showEstimateCreate:     Bool = false
    @State private var showMaterialSaleCreate: Bool = false
    @State private var showClientCreate:       Bool = false

    // Draft resume prompt
    @State private var showResumePrompt:    Bool = false
    @State private var resumableDraft: CommercialContext? = nil

    /// Race guard: SwiftUI `.onChange` callbacks fire on the NEXT view
    /// update cycle, AFTER the synchronous code path that mutated the
    /// state returns. So when `pickClient()` sets `context.clientID`
    /// then immediately calls `openCreateView()` (which calls
    /// `clearDraft()`), the order is:
    ///   1. `clearDraft()` runs and clears UserDefaults
    ///   2. pickClient returns
    ///   3. SwiftUI flushes pending `.onChange` → `saveDraft()` runs
    ///      and RE-WRITES the cleared draft back to UserDefaults
    /// Net effect: clearDraft was useless. The user opens intake next
    /// time and the prompt fires again.
    /// Fix: any code that's about to commit (pickClient, selectWorkType,
    /// openCreateView) flips this flag BEFORE mutating context. The
    /// `.onChange` handlers check it and skip the save. Once the
    /// intake view dismisses, the @State is destroyed — next open is
    /// a fresh instance with the flag back to false.
    @State private var suppressDraftSave: Bool = false

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .workType:     workTypeStep
                case .clientSelect: clientSelectStep
                }
            }
            .navigationTitle(step == .workType ? "New Commercial Work" : "Select Client")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if step == .workType {
                        Button("Cancel") {
                            // Explicit user-driven exit — clear any
                            // mid-intake draft so the user isn't nagged
                            // with a "Resume previous work?" prompt next
                            // time they open the hub. Pre-fix Cancel
                            // just dismissed and left the draft behind.
                            CommercialContext.clearDraft()
                            dismiss()
                        }
                    } else {
                        Button {
                            withAnimation { step = .workType }
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    }
                }

                // Skip client selection (work type only context — downstream handles client)
                if step == .clientSelect {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Skip") { openCreateView() }
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
            }
            // Create view sheets — onDismiss auto-closes intake so user returns to the
            // previous tab rather than a partial intake screen.
            .sheet(isPresented: $showEstimateCreate, onDismiss: { dismiss() }) {
                EstimateCreateView(context: context)
                    .environmentObject(store)
            }
            .sheet(isPresented: $showMaterialSaleCreate, onDismiss: { dismiss() }) {
                MaterialSaleCreateEditView(context: context)
                    .environmentObject(store)
            }
            .sheet(isPresented: $showClientCreate) {
                ClientCreateEditView()
                    .environmentObject(store)
                    .onDisappear {
                        // After creating a new client, the newest client added is pre-selected
                        if let newest = store.clients
                            .filter({ $0.isActive && !$0.isDeleted })
                            .sorted(by: { $0.createdAt > $1.createdAt })
                            .first {
                            // Suppress draft save BEFORE mutating context
                            // so even the first onChange queued by the
                            // mutation below sees the flag set.
                            suppressDraftSave  = true
                            context.clientID   = newest.id
                            context.clientName = newest.name
                            openCreateView()
                        }
                    }
            }
            .onAppear(perform: applyPrefill)
            .onChange(of: context.workType) { _, _ in
                // Skip if a routing commit is in flight — see
                // suppressDraftSave doc above.
                guard !suppressDraftSave else { return }
                context.saveDraft()
            }
            .onChange(of: context.clientID) { _, _ in
                guard !suppressDraftSave else { return }
                context.saveDraft()
            }
            .alert("Resume previous work?", isPresented: $showResumePrompt) {
                Button("Resume") {
                    if let draft = resumableDraft {
                        context = draft
                        if context.workType != nil && context.clientID != nil {
                            openCreateView()
                        } else if context.workType != nil {
                            step = .clientSelect
                        }
                    }
                }
                Button("Start fresh", role: .destructive) {
                    CommercialContext.clearDraft()
                }
            } message: {
                Text("You have an unfinished commercial intake from a previous session.")
            }
        }
    }

    // MARK: - Step 1: Work Type

    private var workTypeStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // Header
                VStack(alignment: .leading, spacing: 6) {
                    Text("What type of work is this?")
                        .font(.title2).bold()
                    Text("All commercial work is automatically linked to a CRM opportunity.")
                        .font(.subheadline).foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.top, 8)

                // ── Estimate-Based Flows ────────────────────────────────────────
                GroupBox {
                    VStack(spacing: 0) {
                        CommercialTypeTile(
                            saleType: .projectWork,
                            subtitle: "Formal estimate → quote → project creation",
                            onTap: { selectWorkType(.projectWork) }
                        )
                        Divider().padding(.leading, 56)
                        CommercialTypeTile(
                            saleType: .serviceWork,
                            subtitle: "Field service with estimate and quote",
                            onTap: { selectWorkType(.serviceWork) }
                        )
                    }
                } label: {
                    Label("Estimate & Quote Flows", systemImage: "doc.text.magnifyingglass")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(.horizontal)

                // ── Direct Commercial Flows ─────────────────────────────────────
                GroupBox {
                    VStack(spacing: 0) {
                        CommercialTypeTile(
                            saleType: .materialSale,
                            subtitle: "Sell products or materials without a project",
                            onTap: { selectWorkType(.materialSale) }
                        )
                        Divider().padding(.leading, 56)
                        CommercialTypeTile(
                            saleType: .rental,
                            subtitle: "Equipment or tool rental with invoice",
                            onTap: { selectWorkType(.rental) }
                        )
                        Divider().padding(.leading, 56)
                        CommercialTypeTile(
                            saleType: .directInvoice,
                            subtitle: "Bill a client directly — no estimate needed",
                            onTap: { selectWorkType(.directInvoice) }
                        )
                    }
                } label: {
                    Label("Direct Commercial Flows", systemImage: "shippingbox.fill")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(.horizontal)

                // CRM note
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill").foregroundColor(.blue)
                    Text("Every commercial record creates or links to a CRM opportunity. Win/loss, revenue, and activity history update automatically.")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding()
                .background(Color.blue.opacity(0.06))
                .cornerRadius(12)
                .padding(.horizontal)

                Spacer(minLength: 40)
            }
        }
    }

    // MARK: - Step 2: Client Select

    private var filteredClients: [Client] {
        let active = store.clients.filter { $0.isActive && !$0.isDeleted }
        guard !clientSearch.isEmpty else { return active.sorted { $0.name < $1.name } }
        return active
            .filter { $0.name.localizedCaseInsensitiveContains(clientSearch) }
            .sorted { $0.name < $1.name }
    }

    private var clientSelectStep: some View {
        VStack(spacing: 0) {
            // Work type summary banner
            if let wt = context.workType {
                HStack(spacing: 8) {
                    Image(systemName: wt.icon)
                        .font(.subheadline)
                        .foregroundColor(wt.color)
                    Text(wt.displayName)
                        .font(.subheadline).bold()
                    Spacer()
                    Button("Change") {
                        withAnimation { step = .workType }
                    }
                    .font(.caption)
                    .foregroundColor(.blue)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(wt.color.opacity(0.08))
            }

            // Search bar
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search clients…", text: $clientSearch)
                    .autocorrectionDisabled()
            }
            .padding(10)
            .background(Color(.systemGray6))
            .cornerRadius(10)
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Client list
            List {
                // Create new client shortcut
                Section {
                    Button {
                        showClientCreate = true
                    } label: {
                        Label("Create New Client", systemImage: "plus.circle.fill")
                            .foregroundColor(.blue)
                            .font(.subheadline)
                    }
                }

                // Existing clients
                Section("Existing Clients (\(filteredClients.count))") {
                    if filteredClients.isEmpty {
                        Text(clientSearch.isEmpty
                             ? "No clients yet. Create one above."
                             : "No clients match \"\(clientSearch)\".")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(filteredClients) { client in
                            Button {
                                pickClient(client)
                            } label: {
                                ClientIntakeRow(client: client, store: store)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    // MARK: - Actions

    private func selectWorkType(_ type: SaleType) {
        // If picking this work type will route us straight to a
        // create view (because the client is already known from
        // prefill), suppress draft saves before any mutation so the
        // queued `.onChange` after openCreateView() doesn't restore
        // the cleared draft. See suppressDraftSave doc.
        if context.clientID != nil {
            suppressDraftSave = true
        }
        context.workType = type
        if context.clientID != nil {
            // Client already known from prefill — route directly
            openCreateView()
        } else {
            withAnimation { step = .clientSelect }
        }
    }

    private func pickClient(_ client: Client) {
        // Always commits to routing — suppress draft save before any
        // context mutations so the deferred onChange callbacks won't
        // re-save after openCreateView clears.
        suppressDraftSave = true
        context.clientID   = client.id
        context.clientName = client.name
        // Auto-fill primary contact
        if let primary = store.primaryContact(for: client.id) {
            context.contactID   = primary.id
            context.contactName = primary.fullName
        }
        // Auto-fill default site (or only site)
        if client.sites.count == 1 {
            context.siteID      = client.sites[0].id
            context.siteAddress = client.sites[0].formattedAddress
        } else if let def = client.sites.first(where: { $0.isDefault }) {
            context.siteID      = def.id
            context.siteAddress = def.formattedAddress
        }
        openCreateView()
    }

    private func openCreateView() {
        guard let wt = context.workType else { return }
        // Belt-and-suspenders: callers should already have set this,
        // but if any future caller forgets, the clearDraft below is
        // still effective because suppressDraftSave gates the
        // onChange handlers from re-writing.
        suppressDraftSave = true
        // Routing to a downstream create view counts as a successful submit —
        // clear any resumable draft so the user is not nagged on next launch.
        CommercialContext.clearDraft()
        if wt.usesEstimateFlow {
            showEstimateCreate = true
        } else {
            showMaterialSaleCreate = true
        }
    }

    private func applyPrefill() {
        // 1) Pre-fill from caller (e.g. opened from a CRM opportunity) wins.
        if let pre = prefillContext {
            context = pre
            if context.workType != nil && context.clientID != nil {
                openCreateView()
            } else if context.workType != nil {
                step = .clientSelect
            }
            return
        }

        // 2) Otherwise: surface a resumable draft from a prior crashed session.
        if let draft = CommercialContext.loadDraft() {
            resumableDraft = draft
            showResumePrompt = true
        }
    }
}

// MARK: - Client Intake Row

private struct ClientIntakeRow: View {
    let client: Client
    let store: AppStore

    private var activeOpportunityCount: Int {
        store.crmOpportunities.filter {
            $0.clientID == client.id && $0.isActive && !$0.isDeleted
        }.count
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 40, height: 40)
                Text(client.initials)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.blue)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(client.name)
                    .font(.subheadline).bold()
                    .foregroundColor(.primary)
                HStack(spacing: 4) {
                    if let city = client.billingCity, !city.isEmpty {
                        Text(city)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if activeOpportunityCount > 0 {
                        Text("· \(activeOpportunityCount) open opp\(activeOpportunityCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Commercial Type Tile

private struct CommercialTypeTile: View {
    let saleType: SaleType
    let subtitle: String
    let onTap:    () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(saleType.color.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: saleType.icon)
                        .font(.system(size: 18))
                        .foregroundColor(saleType.color)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(saleType.displayName)
                        .font(.subheadline).bold()
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
