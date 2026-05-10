// ContractViews.swift
// Aski IQ — Contract module UI: List, Detail, Create/Edit, AI Review.
//
// Consolidated into one file because every screen shares helpers
// (status pills, risk badges, glossary tap-targets) that are tedious
// to keep in sync across multiple files. Each major view is marked
// with a section header for navigation.

import SwiftUI

// MARK: ─────────────────────────────────────────────────────────────
// MARK: - Contract List
// MARK: ─────────────────────────────────────────────────────────────

/// Filter buckets for the list view's segmented control.
enum ContractListFilter: String, CaseIterable, Identifiable {
    case attention   = "Needs Attention"
    case active      = "Active"
    case draft       = "Draft"
    case allLive     = "All Live"
    case archived    = "Closed"

    var id: String { rawValue }
}

struct ContractListView: View {
    @EnvironmentObject var store: AppStore
    @State private var filter: ContractListFilter = .attention
    @State private var typeFilter: ContractType? = nil
    @State private var search: String = ""
    @State private var showCreate = false

    private var filtered: [Contract] {
        var rows = store.liveContracts

        // Bucket filter
        switch filter {
        case .attention:
            let needyIDs = Set(store.contractsNeedingAttention.map { $0.id })
            rows = rows.filter { needyIDs.contains($0.id) }
        case .active:
            rows = rows.filter { $0.status == .active || $0.status == .expiring || $0.status == .pendingSignature }
        case .draft:
            rows = rows.filter { $0.status == .draft || $0.status == .underReview }
        case .allLive:
            rows = rows.filter {
                $0.status != .completed && $0.status != .terminated && $0.status != .disputed
            }
        case .archived:
            rows = rows.filter {
                $0.status == .completed || $0.status == .terminated || $0.status == .disputed
            }
        }

        // Type filter (optional pill)
        if let t = typeFilter { rows = rows.filter { $0.contractType == t } }

        // Search
        if !search.isEmpty {
            let q = search.lowercased()
            rows = rows.filter {
                $0.title.lowercased().contains(q) ||
                $0.counterpartyName.lowercased().contains(q) ||
                ($0.contractNumber?.lowercased().contains(q) ?? false)
            }
        }

        return rows.sorted { lhs, rhs in
            // Pin attention items to the top, then most-recently-updated.
            let lhsAttn = lhs.isExpiringSoon || store.hasOverdueMilestones(forContract: lhs.id)
            let rhsAttn = rhs.isExpiringSoon || store.hasOverdueMilestones(forContract: rhs.id)
            if lhsAttn != rhsAttn { return lhsAttn && !rhsAttn }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    var body: some View {
        List {
            // Phase 7 / Wave 2: First-launch sync gate. Contracts
            // reference clients, projects, opportunities — all
            // server-resident.
            if !store.hasCompletedFirstSync {
                Section {
                    FirstLaunchSyncGateBanner()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            Section {
                Picker("Filter", selection: $filter) {
                    ForEach(ContractListFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        TypePill(label: "All", icon: "tray.full", isOn: typeFilter == nil) {
                            typeFilter = nil
                        }
                        ForEach(ContractType.allCases) { t in
                            TypePill(label: t.displayName, icon: t.icon, isOn: typeFilter == t) {
                                typeFilter = (typeFilter == t) ? nil : t
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if filtered.isEmpty {
                Section {
                    EmptyContractsRow(filter: filter, onCreate: { showCreate = true })
                }
            } else {
                Section {
                    ForEach(filtered) { c in
                        NavigationLink(value: c.id) {
                            ContractRow(contract: c)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Contracts")
        .navigationDestination(for: UUID.self) { id in
            if let c = store.contracts.first(where: { $0.id == id }) {
                ContractDetailView(contractID: c.id)
            } else {
                Text("Contract not found.")
            }
        }
        .searchable(text: $search, prompt: "Search by title, counterparty, or #")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(!store.hasCompletedFirstSync)
            }
        }
        .sheet(isPresented: $showCreate) {
            ContractCreateEditView()
                .environmentObject(store)
        }
    }
}

// MARK: - List support views

private struct TypePill: View {
    let label: String
    let icon: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isOn ? Color.accentColor.opacity(0.18) : Color(.systemGray6))
                )
                .overlay(
                    Capsule().stroke(isOn ? Color.accentColor : Color.clear, lineWidth: 1)
                )
                .foregroundColor(isOn ? .accentColor : .primary)
        }
        .buttonStyle(.plain)
    }
}

private struct ContractRow: View {
    @EnvironmentObject var store: AppStore
    let contract: Contract

    private var nextMilestone: ContractMilestone? {
        store.milestones(forContract: contract.id)
            .first(where: { $0.effectiveStatus != .completed && $0.effectiveStatus != .waived })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: contract.contractType.icon)
                    .foregroundColor(.accentColor)
                    .font(.subheadline)
                Text(contract.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                ContractStatusBadge(status: contract.effectiveStatus)
            }
            HStack(spacing: 6) {
                Text(contract.counterpartyName)
                    .font(.caption).foregroundColor(.secondary)
                if let n = contract.contractNumber {
                    Text("· \(n)").font(.caption).foregroundColor(.secondary)
                }
                if let v = contract.contractValue {
                    Text("· \(v.formatted(.currency(code: contract.currency)))")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.primary)
                }
            }
            HStack(spacing: 10) {
                if let risk = contract.riskScore {
                    RiskPill(level: risk)
                }
                if let m = nextMilestone {
                    Label(milestoneSummary(m),
                          systemImage: m.milestoneType.icon)
                        .font(.caption2)
                        .foregroundColor(milestoneColor(m))
                }
                if contract.isExpiringSoon, let d = contract.daysUntilExpiry {
                    Label("Expires in \(d) days", systemImage: "calendar.badge.exclamationmark")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func milestoneSummary(_ m: ContractMilestone) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d"
        let datestr = f.string(from: m.milestoneDate)
        switch m.effectiveStatus {
        case .overdue:  return "OVERDUE: \(m.title) (\(datestr))"
        case .due:      return "DUE TODAY: \(m.title)"
        default:        return "\(m.title) · \(datestr)"
        }
    }
    private func milestoneColor(_ m: ContractMilestone) -> Color {
        switch m.effectiveStatus {
        case .overdue:  return .red
        case .due:      return .orange
        default:        return .secondary
        }
    }
}

private struct ContractStatusBadge: View {
    let status: ContractStatus
    var body: some View {
        Text(status.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundColor(color)
    }
    private var color: Color {
        switch status {
        case .draft, .underReview:        return .secondary
        case .sent, .pendingSignature:    return .blue
        case .active:                     return .green
        case .expiring:                   return .orange
        case .completed:                  return .gray
        case .terminated, .disputed:      return .red
        }
    }
}

private struct RiskPill: View {
    let level: RiskLevel
    var body: some View {
        Label(level.displayName, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundColor(color)
    }
    private var color: Color {
        switch level {
        case .low:      return .green
        case .medium:   return .yellow
        case .high:     return .orange
        case .critical: return .red
        }
    }
    private var icon: String {
        switch level {
        case .low:      return "checkmark.shield.fill"
        case .medium:   return "exclamationmark.shield"
        case .high:     return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }
}

private struct EmptyContractsRow: View {
    let filter: ContractListFilter
    let onCreate: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("No \(filter.rawValue.lowercased()) contracts yet.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button {
                onCreate()
            } label: {
                Label("New contract", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

// MARK: ─────────────────────────────────────────────────────────────
// MARK: - Contract Detail
// MARK: ─────────────────────────────────────────────────────────────

struct ContractDetailView: View {
    @EnvironmentObject var store: AppStore
    let contractID: UUID

    @State private var selectedTab: DetailTab = .summary
    @State private var showEdit = false
    @State private var showAIReview = false
    @State private var showAddMilestone = false
    @State private var showUploadDoc = false
    @State private var showAddCompliance = false
    @State private var editingComplianceDoc: ComplianceDocument? = nil
    /// Captured by `ContractDocumentUploadSheet` when a PDF is uploaded
    /// and PDFKit extracts its text. Auto-pre-fills the AI Review Sheet
    /// the next time it opens — saves the user a copy-paste step.
    /// In-memory only; doesn't persist across app launches by design,
    /// since the contract's primary document URL is the durable record.
    @State private var lastExtractedText: String? = nil
    @State private var showAddLienWaiver = false
    @State private var editingWaiver: LienWaiver? = nil
    @State private var showRevokeSignOffConfirm = false
    @State private var pendingSignOffURL: URL? = nil
    @State private var showSignOffShare = false
    @State private var showAIDiff = false
    @State private var showBulkWaivers = false

    /// Dropbox Sign / HelloSign send sheet. Distinct from the existing
    /// `mintSignOffLink` magic-link flow — that one is our homegrown
    /// counterpart-portal page; this one routes the contract through
    /// a real e-signature provider with audit trail + signed PDF.
    @State private var showESignSheet = false
    /// Phase-2 deferred audit fix: confirm dialog for the destructive
    /// "Reset AI-extracted data" action.
    @State private var showResetAIConfirm = false

    enum DetailTab: String, CaseIterable, Identifiable {
        case summary    = "Summary"
        case clauses    = "Clauses"
        case milestones = "Milestones"
        case checklist  = "Checklist"
        case compliance = "Compliance"
        case waivers    = "Waivers"
        case documents  = "Docs"
        case notes      = "Notes"
        var id: String { rawValue }
    }

    private var contract: Contract? {
        store.contracts.first(where: { $0.id == contractID })
    }

    var body: some View {
        Group {
            if let c = contract {
                VStack(spacing: 0) {
                    headerCard(for: c)
                    Picker("", selection: $selectedTab) {
                        ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    Divider()
                    ScrollView {
                        switch selectedTab {
                        case .summary:    summaryTab(for: c)
                        case .clauses:    clausesTab(for: c)
                        case .milestones: milestonesTab(for: c)
                        case .checklist:  checklistTab(for: c)
                        case .compliance: complianceTab(for: c)
                        case .waivers:    waiversTab(for: c)
                        case .documents:  documentsTab(for: c)
                        case .notes:      notesTab(for: c)
                        }
                    }
                }
            } else {
                ContentUnavailableView("Contract not found",
                                       systemImage: "doc.text",
                                       description: Text("It may have been deleted."))
            }
        }
        .navigationTitle(contract?.contractNumber ?? "Contract")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if contract != nil {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { showEdit = true } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button { showAIReview = true } label: {
                            Label("AI Review", systemImage: "wand.and.stars")
                        }
                        Button { showAIDiff = true } label: {
                            Label("AI Diff vs prior version", systemImage: "arrow.triangle.2.circlepath")
                        }
                        // Phase-2 deferred audit fix: admin-only escape
                        // hatch when AI Review extracts garbage. Nukes
                        // AI clauses, milestones it created, compliance
                        // requirements it created, and the extracted
                        // summary fields on the contract itself.
                        // Manual data is left alone.
                        if store.currentUserRole.isAdmin {
                            Button(role: .destructive) {
                                showResetAIConfirm = true
                            } label: {
                                Label("Reset AI-extracted data",
                                      systemImage: "wand.and.stars.inverse")
                            }
                        }
                        // Magic-link sign-off: mints a token, presents
                        // the URL via the share sheet so the admin can
                        // paste into email / SMS / etc. Admin-only;
                        // server enforces.
                        if store.currentUserRole.isAdmin {
                            // Provider-backed e-signature (Dropbox Sign).
                            // Goes through `signing-create-request` Edge
                            // Function. Disabled when there's no PDF
                            // attached to the contract — Dropbox Sign
                            // needs something to sign.
                            Button {
                                showESignSheet = true
                            } label: {
                                Label("Send via Dropbox Sign",
                                      systemImage: "doc.badge.plus")
                            }
                            .disabled(contract?.primaryDocumentURL == nil)

                            Button {
                                Task { await mintSignOffLink() }
                            } label: {
                                Label("Send magic-link sign-off",
                                      systemImage: "signature")
                            }
                            Button(role: .destructive) {
                                showRevokeSignOffConfirm = true
                            } label: {
                                Label("Revoke sign-off link", systemImage: "xmark.circle")
                            }
                        }
                        if selectedTab == .milestones {
                            Button { showAddMilestone = true } label: {
                                Label("Add milestone", systemImage: "calendar.badge.plus")
                            }
                        }
                        if selectedTab == .waivers {
                            Button { showAddLienWaiver = true } label: {
                                Label("Add lien waiver", systemImage: "shield.lefthalf.filled")
                            }
                            // Bulk send: pick N subs, set common terms,
                            // fire magic-link waivers in one action.
                            if store.currentUserRole.isAdmin {
                                Button { showBulkWaivers = true } label: {
                                    Label("Bulk request waivers",
                                          systemImage: "tray.and.arrow.up.fill")
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showEdit) {
            if let c = contract {
                ContractCreateEditView(existing: c)
                    .environmentObject(store)
            }
        }
        .sheet(isPresented: $showAIReview) {
            if let c = contract {
                ContractAIReviewSheet(contract: c, prefillText: lastExtractedText)
                    .environmentObject(store)
            }
        }
        .sheet(isPresented: $showAIDiff) {
            if let c = contract {
                // Pre-fill the OLD baseline with whatever PDF text was
                // extracted on the most recent upload — so the user
                // only has to paste the redline. Clean fallback to
                // empty when nothing's been uploaded.
                ContractDiffSheet(contract: c, prefillOldText: lastExtractedText)
                    .environmentObject(store)
            }
        }
        .sheet(isPresented: $showBulkWaivers) {
            if let c = contract {
                BulkLienWaiverSheet(contract: c)
                    .environmentObject(store)
            }
        }
        .sheet(isPresented: $showAddMilestone) {
            if let c = contract {
                ContractMilestoneEditSheet(contractID: c.id)
                    .environmentObject(store)
            }
        }
        .sheet(isPresented: $showUploadDoc) {
            if let c = contract {
                ContractDocumentUploadSheet(contract: c) { extracted in
                    // Caches the extracted PDF text so the AI Review
                    // sheet that opens next can pre-fill its editor.
                    lastExtractedText = extracted
                }
                .environmentObject(store)
            }
        }
        .sheet(isPresented: $showAddCompliance) {
            if let c = contract {
                ComplianceDocumentEditSheet(contractID: c.id, existing: nil)
                    .environmentObject(store)
            }
        }
        .sheet(item: $editingComplianceDoc) { doc in
            ComplianceDocumentEditSheet(contractID: doc.contractID ?? UUID(),
                                        existing: doc)
                .environmentObject(store)
        }
        .sheet(isPresented: $showAddLienWaiver) {
            if let c = contract {
                LienWaiverEditSheet(contractID: c.id, existing: nil)
                    .environmentObject(store)
            }
        }
        .sheet(item: $editingWaiver) { w in
            LienWaiverEditSheet(contractID: w.contractID ?? UUID(),
                                existing: w)
                .environmentObject(store)
        }
        .sheet(isPresented: $showSignOffShare) {
            if let url = pendingSignOffURL {
                ShareSheet(items: [url.absoluteString])
            }
        }
        .sheet(isPresented: $showESignSheet) {
            if let c = contract {
                ContractSendForSigningSheet(contract: c) {
                    // After send completes, force a refresh so the
                    // contract's signature_status (set server-side)
                    // pulls down on the next sync.
                    Task { await store.refreshAll() }
                    ToastService.shared.success("Signature request sent.")
                }
            }
        }
        .alert("Revoke sign-off link?", isPresented: $showRevokeSignOffConfirm) {
            Button("Revoke", role: .destructive) {
                Task { await revokeSignOff() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The counterparty's link will stop working immediately. You can mint a new one any time.")
        }
        .alert("Reset all AI-extracted data?", isPresented: $showResetAIConfirm) {
            Button("Reset", role: .destructive) {
                store.resetAIExtractedData(for: contractID)
                ToastService.shared.warning("AI-extracted data cleared. Re-run AI Review when you're ready.")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This wipes every clause, milestone, and compliance requirement created by AI Review on this contract — plus the extracted summary fields (payment terms, retainage, warranty, governing law, dispute resolution, insurance/bond flags, risk score). Manually-entered data is preserved. The action is logged in the audit trail.")
        }
    }

    // MARK: - Sign-off action handlers

    /// Mint a contract sign-off magic link and either:
    ///   • auto-email it to `contract.counterpartyEmail` when set, or
    ///   • fall back to the share sheet so the operator can route the link
    ///     manually (preserves the legacy behavior for contracts whose
    ///     counterparty email isn't on file yet).
    private func mintSignOffLink() async {
        guard let c = contract else { return }
        do {
            let result = try await ContractAcceptanceService.shared.mintToken(contractID: c.id)
            pendingSignOffURL = result.url

            let recipient = c.counterpartyEmail?.trimmingCharacters(in: .whitespaces)
            if let email = recipient, !email.isEmpty {
                let mailResult = await EmailService.shared.sendText(
                    to:         [email],
                    subject:    contractSignOffEmailSubject(contract: c),
                    bodyText:   contractSignOffEmailBody(contract: c, url: result.url),
                    entityType: "contract",
                    entityID:   c.id
                )
                switch mailResult {
                case .success:
                    ToastService.shared.success("Sign-off link emailed to \(email).")
                case .failure(let err):
                    showSignOffShare = true
                    ToastService.shared.error("Couldn't email link: \(err.userMessage). Share manually.")
                }
            } else {
                showSignOffShare = true
                ToastService.shared.success("Sign-off link minted — share via email or message.")
            }
        } catch let err as ContractAcceptanceService.AcceptanceError {
            ToastService.shared.error(err.errorDescription ?? "Couldn't mint link")
        } catch {
            ToastService.shared.error(error.localizedDescription)
        }
    }

    private func contractSignOffEmailSubject(contract c: Contract) -> String {
        let company = AppSettings.shared.companyName.isEmpty
            ? "Aski IQ"
            : AppSettings.shared.companyName
        let label = c.title.isEmpty ? "contract" : c.title
        return "Sign-off request — \(label) — \(company)"
    }

    private func contractSignOffEmailBody(contract c: Contract, url: URL) -> String {
        let signer = AppSettings.shared.companyName.isEmpty
            ? "Aski IQ"
            : AppSettings.shared.companyName
        let title = c.title.isEmpty ? "this contract" : c.title
        return """
        Hello,

        Please review and sign \(title) using the secure link below:

        \(url.absoluteString)

        This link is unique to you and will expire after 30 days. Reply to this email if you have any questions.

        Thanks,
        \(signer)
        """
    }

    private func revokeSignOff() async {
        guard let c = contract else { return }
        do {
            try await ContractAcceptanceService.shared.revoke(contractID: c.id)
            ToastService.shared.warning("Sign-off link revoked.")
        } catch {
            ToastService.shared.error("Couldn't revoke: \(error.localizedDescription)")
        }
    }

    // MARK: Header

    private func headerCard(for c: Contract) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: c.contractType.icon).foregroundColor(.accentColor)
                Text(c.title).font(.title3.weight(.semibold)).lineLimit(2)
                Spacer()
                ContractStatusBadge(status: c.effectiveStatus)
            }
            HStack(spacing: 12) {
                Text(c.counterpartyName)
                    .font(.subheadline).foregroundColor(.secondary)
                if let v = c.contractValue {
                    Text(v.formatted(.currency(code: c.currency)))
                        .font(.subheadline.weight(.semibold))
                }
            }
            if c.aiReviewStatus == .reviewed, let risk = c.riskScore {
                HStack(spacing: 8) {
                    RiskPill(level: risk)
                    Text("AI-reviewed")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                }
            } else if c.aiReviewStatus == .reviewing {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("AI review in progress…").font(.caption).foregroundColor(.secondary)
                }
            }
            // Magic-link sign-off status. Only renders once a token has
            // been minted; before that, an empty view collapses the row.
            ContractSignOffPill(contractID: c.id)
        }
        .padding()
    }

    // MARK: Tabs

    private func summaryTab(for c: Contract) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let summary = c.riskSummary {
                SectionCard(title: "Risk summary", icon: "shield.lefthalf.filled") {
                    Text(summary).font(.subheadline)
                }
            }
            SectionCard(title: "Key dates", icon: "calendar") {
                KeyDatesGrid(contract: c)
            }
            SectionCard(title: "Key terms", icon: "doc.badge.gearshape") {
                KeyTermsGrid(contract: c)
            }
        }
        .padding()
    }

    private func clausesTab(for c: Contract) -> some View {
        let clauses = store.clauses(forContract: c.id)
        return VStack(alignment: .leading, spacing: 12) {
            if clauses.isEmpty {
                EmptyStateMessage(
                    icon: "wand.and.stars",
                    title: "No clauses extracted yet.",
                    subtitle: "Run an AI review to extract and explain the material clauses in this contract.",
                    actionTitle: "Run AI Review",
                    action: { showAIReview = true }
                )
                .padding(.top, 32)
            } else {
                ForEach(clauses) { ClauseCard(clause: $0) }
            }
        }
        .padding()
    }

    private func milestonesTab(for c: Contract) -> some View {
        let milestones = store.milestones(forContract: c.id)
        return VStack(alignment: .leading, spacing: 10) {
            if milestones.isEmpty {
                EmptyStateMessage(
                    icon: "calendar.badge.plus",
                    title: "No milestones yet.",
                    subtitle: "Add payment-due dates, retainage release, insurance renewal — they'll show up on the Schedule tab.",
                    actionTitle: "Add milestone",
                    action: { showAddMilestone = true }
                )
                .padding(.top, 32)
            } else {
                ForEach(milestones) { MilestoneRow(milestone: $0) }
            }
        }
        .padding()
    }

    private func notesTab(for c: Contract) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let n = c.notes, !n.isEmpty {
                Text(n).font(.subheadline)
            } else {
                Text("No notes yet. Tap Edit to add.")
                    .font(.subheadline).foregroundColor(.secondary)
            }
        }
        .padding()
    }

    // MARK: - New Phase 2A tabs

    private func checklistTab(for c: Contract) -> some View {
        let definition  = ContractChecklists.checklist(for: c.contractType)
        let clauses     = store.clauses(forContract: c.id)
        let autoChecked = ContractChecklists.autoCheckedItems(for: clauses)
        let manual      = ChecklistManualState.manualChecked(from: c.notes)
        let state = ContractChecklistState(
            definition:    definition,
            autoChecked:   autoChecked,
            manualChecked: manual
        )

        return VStack(alignment: .leading, spacing: AskiSpacing.md) {
            // Progress + title
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(definition.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(state.checkedCount) / \(state.totalCount)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                ProgressView(value: state.progress)
                    .tint(state.progress == 1.0 ? .green : .accentColor)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)

            // Items
            ForEach(definition.items) { item in
                ChecklistItemRow(
                    item:        item,
                    isAutoCheck: state.autoChecked.contains(item.id),
                    isManualCheck: state.manualChecked.contains(item.id),
                    onToggle: {
                        toggleManualCheck(itemID: item.id, on: c)
                    }
                )
            }
        }
        .padding()
    }

    private func complianceTab(for c: Contract) -> some View {
        let docs = store.complianceDocs(forContract: c.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Insurance & bonds").font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    showAddCompliance = true
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                        .font(.subheadline)
                }
            }
            if docs.isEmpty {
                EmptyStateMessage(
                    icon: "shield.lefthalf.filled",
                    title: "No insurance or bonds tracked yet.",
                    subtitle: "Add an insurance certificate or surety bond. Expiry warnings auto-show on the Schedule tab.",
                    actionTitle: "Add document",
                    action: { showAddCompliance = true }
                )
                .padding(.top, 24)
            } else {
                ForEach(docs) { d in
                    ComplianceRow(doc: d) {
                        editingComplianceDoc = d
                    }
                }
            }
        }
        .padding()
    }

    private func waiversTab(for c: Contract) -> some View {
        let waivers = store.lienWaivers(forContract: c.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Lien waivers").font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    showAddLienWaiver = true
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                        .font(.subheadline)
                }
            }
            if waivers.isEmpty {
                EmptyStateMessage(
                    icon: "shield.lefthalf.filled",
                    title: "No lien waivers tracked yet.",
                    subtitle: "Capture a waiver per progress payment so subs can't surprise-lien you. Conditional waivers tie to invoices; unconditional waivers go in only after funds clear.",
                    actionTitle: "Add waiver",
                    action: { showAddLienWaiver = true }
                )
                .padding(.top, 24)
            } else {
                ForEach(waivers) { w in
                    LienWaiverRow(waiver: w) {
                        editingWaiver = w
                    }
                }
            }
        }
        .padding()
    }

    private func documentsTab(for c: Contract) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Primary contract").font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    showUploadDoc = true
                } label: {
                    Label(c.primaryDocumentURL == nil ? "Upload PDF" : "Replace PDF",
                          systemImage: "arrow.up.doc.fill")
                        .font(.subheadline)
                }
            }
            if let path = c.primaryDocumentURL {
                DocumentLinkRow(filename: c.primaryDocumentName ?? path,
                                storagePath: path)
            } else {
                EmptyStateMessage(
                    icon: "doc.fill.badge.plus",
                    title: "No primary document yet.",
                    subtitle: "Upload the executed PDF. We'll extract the text so AI review doesn't need copy-paste.",
                    actionTitle: "Upload PDF",
                    action: { showUploadDoc = true }
                )
                .padding(.top, 24)
            }
        }
        .padding()
    }

    // MARK: - Manual checklist persistence

    /// Manual check toggles are stored in the contract's notes JSON
    /// so we don't need a new table for V1. Keeps it portable; phase 2B
    /// can move to a proper `contract_checklist_state` row.
    private func toggleManualCheck(itemID: String, on contract: Contract) {
        var manual = ChecklistManualState.manualChecked(from: contract.notes)
        if manual.contains(itemID) { manual.remove(itemID) }
        else                       { manual.insert(itemID) }
        var updated = contract
        updated.notes = ChecklistManualState.encode(manual: manual,
                                                    intoExisting: contract.notes)
        store.upsertContract(updated)
    }
}

// MARK: - Manual checklist state encoding helper
//
// Manual check state piggy-backs on the contract's `notes` field as a
// JSON marker block at the very end. Reasons:
//   * No new table for V1
//   * Visible in raw exports
//   * Trivially round-tripped through any sync layer
// If the user types text in the notes field, we preserve it; the
// state block is appended below a delimiter and stripped on read.

private enum ChecklistManualState {
    private static let marker = "\n\n[checklist-state]"

    static func manualChecked(from notes: String?) -> Set<String> {
        guard let notes,
              let range = notes.range(of: marker) else { return [] }
        let payload = notes[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = payload.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(arr)
    }

    static func encode(manual: Set<String>, intoExisting notes: String?) -> String {
        let humanPart: String
        if let notes,
           let range = notes.range(of: marker) {
            humanPart = String(notes[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            humanPart = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let arr = Array(manual).sorted()
        let json: String = (try? String(data: JSONEncoder().encode(arr), encoding: .utf8)) ?? "[]"
        return humanPart.isEmpty
            ? marker + "\n" + json
            : humanPart + marker + "\n" + json
    }
}

// MARK: - Detail support views

private struct SectionCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            content()
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

private struct KeyDatesGrid: View {
    let contract: Contract
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Effective", contract.effectiveDate)
            row("Executed",  contract.executedDate)
            row("Expires",   contract.expiryDate)
            row("Renewal",   contract.renewalDate)
            row("Terminated", contract.terminationDate)
        }
    }
    private func row(_ label: String, _ d: Date?) -> some View {
        HStack {
            Text(label).font(.caption).foregroundColor(.secondary)
            Spacer()
            Text(d.map { Self.df.string(from: $0) } ?? "—").font(.caption)
        }
    }
    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; return f
    }()
}

private struct KeyTermsGrid: View {
    let contract: Contract
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Payment terms",    contract.paymentTerms)
            row("Retainage %",      contract.retainagePercent.map { "\($0)%" })
            row("Warranty (days)",  contract.warrantyPeriodDays.map { "\($0)" })
            row("Insurance req'd",  contract.insuranceRequired ? "Yes" : "No")
            row("Bond req'd",       contract.bondRequired ? "Yes" : "No")
            row("Governing law",    contract.governingLaw)
            row("Dispute resolution", contract.disputeResolution)
        }
    }
    private func row(_ label: String, _ v: String?) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Spacer()
            Text(v?.isEmpty == false ? v! : "—")
                .font(.caption)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct ClauseCard: View {
    let clause: ContractClause
    @State private var showGlossary = false
    @State private var glossaryEntry: ContractGlossaryEntry? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(clause.title ?? clause.clauseKind.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let r = clause.riskLevel { RiskPill(level: r) }
                Button {
                    glossaryEntry = ContractGlossary.shared.lookup(clause.clauseKind.displayName)
                    showGlossary = (glossaryEntry != nil)
                } label: {
                    Image(systemName: "questionmark.circle")
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }
            if let plain = clause.plainEnglish {
                Text(plain).font(.subheadline)
            }
            if let why = clause.riskExplanation {
                Label(why, systemImage: "exclamationmark.bubble")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if let orig = clause.originalText, !orig.isEmpty {
                DisclosureGroup("Show original text") {
                    Text(orig)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
                .font(.caption)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .sheet(isPresented: $showGlossary) {
            if let e = glossaryEntry { GlossaryEntrySheet(entry: e) }
        }
    }
}

private struct MilestoneRow: View {
    @EnvironmentObject var store: AppStore
    let milestone: ContractMilestone
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: milestone.milestoneType.icon)
                .foregroundColor(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(milestone.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(milestone.effectiveStatus.displayName.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(color)
                }
                HStack(spacing: 8) {
                    Text(Self.df.string(from: milestone.milestoneDate))
                        .font(.caption).foregroundColor(.secondary)
                    if let v = milestone.amountDue {
                        Text("· " + v.formatted(.currency(code: "USD")))
                            .font(.caption.weight(.semibold))
                    }
                }
                if let n = milestone.description, !n.isEmpty {
                    Text(n).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .swipeActions(edge: .trailing) {
            if milestone.effectiveStatus != .completed {
                Button {
                    var m = milestone
                    m.status = .completed
                    m.completedAt = Date()
                    store.upsertContractMilestone(m)
                } label: {
                    Label("Done", systemImage: "checkmark")
                }.tint(.green)
            }
        }
    }
    private var color: Color {
        switch milestone.effectiveStatus {
        case .overdue:    return .red
        case .due:        return .orange
        case .upcoming:   return .blue
        case .completed:  return .green
        case .waived:     return .secondary
        }
    }
    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; return f
    }()
}

private struct EmptyStateMessage: View {
    let icon: String
    let title: String
    let subtitle: String
    let actionTitle: String
    let action: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text(title).font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

// MARK: ─────────────────────────────────────────────────────────────
// MARK: - Contract Create / Edit
// MARK: ─────────────────────────────────────────────────────────────

struct ContractCreateEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var contractType: ContractType = .ownerPrime
    @State private var status: ContractStatus = .draft
    @State private var counterpartyType: CounterpartyType = .client
    @State private var counterpartyName: String = ""
    @State private var counterpartyEmail: String = ""
    @State private var contractValueText: String = ""
    @State private var currency: String = "USD"
    @State private var retainageText: String = ""
    @State private var effectiveDate: Date? = nil
    @State private var expiryDate: Date? = nil
    @State private var executedDate: Date? = nil
    @State private var paymentTerms: String = ""
    @State private var insuranceRequired: Bool = false
    @State private var bondRequired: Bool = false
    @State private var governingLaw: String = ""
    @State private var disputeResolution: String = ""
    @State private var notes: String = ""

    private let editing: Contract?

    init(existing: Contract? = nil) {
        self.editing = existing
        if let c = existing {
            _title             = State(initialValue: c.title)
            _contractType      = State(initialValue: c.contractType)
            _status            = State(initialValue: c.status)
            _counterpartyType  = State(initialValue: c.counterpartyType ?? .client)
            _counterpartyName  = State(initialValue: c.counterpartyName)
            _counterpartyEmail = State(initialValue: c.counterpartyEmail ?? "")
            _contractValueText = State(initialValue: c.contractValue.map { "\($0)" } ?? "")
            _currency          = State(initialValue: c.currency)
            _retainageText     = State(initialValue: c.retainagePercent.map { "\($0)" } ?? "")
            _effectiveDate     = State(initialValue: c.effectiveDate)
            _expiryDate        = State(initialValue: c.expiryDate)
            _executedDate      = State(initialValue: c.executedDate)
            _paymentTerms      = State(initialValue: c.paymentTerms ?? "")
            _insuranceRequired = State(initialValue: c.insuranceRequired)
            _bondRequired      = State(initialValue: c.bondRequired)
            _governingLaw      = State(initialValue: c.governingLaw ?? "")
            _disputeResolution = State(initialValue: c.disputeResolution ?? "")
            _notes             = State(initialValue: c.notes ?? "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Title (required)", text: $title)
                    Picker("Type", selection: $contractType) {
                        ForEach(ContractType.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Status", selection: $status) {
                        ForEach([ContractStatus.draft, .underReview, .sent, .pendingSignature,
                                  .active, .completed, .terminated, .disputed]) {
                            Text($0.displayName).tag($0)
                        }
                    }
                }

                Section("Counterparty") {
                    Picker("Role", selection: $counterpartyType) {
                        ForEach(CounterpartyType.allCases) { Text($0.displayName).tag($0) }
                    }
                    TextField("Name", text: $counterpartyName)
                    TextField("Email (optional)", text: $counterpartyEmail)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                }

                Section("Money") {
                    TextField("Contract value", text: $contractValueText)
                        .keyboardType(.decimalPad)
                    TextField("Currency", text: $currency)
                    TextField("Retainage % (optional)", text: $retainageText)
                        .keyboardType(.decimalPad)
                    TextField("Payment terms (e.g. Net 30, milestone)", text: $paymentTerms)
                }

                Section("Dates") {
                    OptionalDateField(label: "Effective",  date: $effectiveDate)
                    OptionalDateField(label: "Executed",   date: $executedDate)
                    OptionalDateField(label: "Expires",    date: $expiryDate)
                }

                Section("Risk surface") {
                    Toggle("Insurance required", isOn: $insuranceRequired)
                    Toggle("Bond required",      isOn: $bondRequired)
                    TextField("Governing law (e.g. Alberta)", text: $governingLaw)
                    TextField("Dispute method (mediation / arbitration / courts)",
                              text: $disputeResolution)
                }

                Section("Notes") {
                    TextEditor(text: $notes).frame(minHeight: 100)
                }
            }
            .navigationTitle(editing == nil ? "New Contract" : "Edit Contract")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty
                                  || counterpartyName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .bold()
                }
            }
        }
    }

    private func save() {
        var c = editing ?? Contract(
            title: title,
            contractType: contractType,
            counterpartyName: counterpartyName
        )
        c.title             = title
        c.contractType      = contractType
        c.status            = status
        c.counterpartyType  = counterpartyType
        c.counterpartyName  = counterpartyName
        c.counterpartyEmail = counterpartyEmail.isEmpty ? nil : counterpartyEmail
        c.contractValue     = Decimal(string: contractValueText)
        c.currency          = currency.isEmpty ? "USD" : currency
        c.retainagePercent  = Decimal(string: retainageText)
        c.effectiveDate     = effectiveDate
        c.expiryDate        = expiryDate
        c.executedDate      = executedDate
        c.paymentTerms      = paymentTerms.isEmpty ? nil : paymentTerms
        c.insuranceRequired = insuranceRequired
        c.bondRequired      = bondRequired
        c.governingLaw      = governingLaw.isEmpty ? nil : governingLaw
        c.disputeResolution = disputeResolution.isEmpty ? nil : disputeResolution
        c.notes             = notes.isEmpty ? nil : notes
        store.upsertContract(c)
        dismiss()
    }
}

// MARK: - Optional date field

private struct OptionalDateField: View {
    let label: String
    @Binding var date: Date?
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            if let d = date {
                DatePicker("", selection: Binding(
                    get: { d },
                    set: { date = $0 }
                ), displayedComponents: .date)
                .labelsHidden()
                Button {
                    date = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Button("Set") { date = Date() }
                    .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: ─────────────────────────────────────────────────────────────
// MARK: - AI Review Sheet
// MARK: ─────────────────────────────────────────────────────────────

struct ContractAIReviewSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let contract: Contract
    /// Optional text auto-extracted from the uploaded PDF. When
    /// provided, the editor pre-fills with it so the user can review
    /// + tap Run without re-pasting from another app.
    let prefillText: String?

    @State private var contractText: String = ""
    @State private var mode: ContractReviewService.ReviewMode = .lightweight
    @State private var isReviewing = false
    @State private var error: String? = nil
    @State private var resultPreview: ContractReviewService.ReviewResult? = nil
    /// While loading text from an uploaded document. Disables the
    /// editor + Run button so we don't fire mid-fetch.
    @State private var isLoadingDoc = false

    init(contract: Contract, prefillText: String? = nil) {
        self.contract     = contract
        self.prefillText  = prefillText
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Depth", selection: $mode) {
                        Text(ContractReviewService.ReviewMode.lightweight.displayName)
                            .tag(ContractReviewService.ReviewMode.lightweight)
                        Text(ContractReviewService.ReviewMode.deep.displayName)
                            .tag(ContractReviewService.ReviewMode.deep)
                    }
                    .pickerStyle(.segmented)
                    Text(modeFooter)
                        .font(.caption).foregroundColor(.secondary)
                }

                // ── Source picker ──────────────────────────────────
                // If the contract has an uploaded primary document,
                // offer a one-tap "Load from uploaded PDF" so the user
                // doesn't need to copy-paste.
                if let path = contract.primaryDocumentURL {
                    Section {
                        Button {
                            Task { await loadFromUploadedDocument(path) }
                        } label: {
                            HStack {
                                if isLoadingDoc {
                                    ProgressView().scaleEffect(0.85)
                                    Text("Extracting text from PDF…")
                                } else {
                                    Image(systemName: "doc.text.fill")
                                        .foregroundColor(.accentColor)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Load from uploaded PDF")
                                            .font(.subheadline.weight(.semibold))
                                        Text(contract.primaryDocumentName ?? path)
                                            .font(.caption.monospacedDigit())
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                        }
                        .disabled(isLoadingDoc)
                    } footer: {
                        Text("Pulls the text directly from the document attached to this contract — no copy-paste needed. PDFs only; DOCX support coming later.")
                    }
                }

                Section {
                    TextEditor(text: $contractText)
                        .frame(minHeight: 200)
                        .font(.system(.body, design: .monospaced))
                        .disabled(isLoadingDoc)
                } header: {
                    Text(contract.primaryDocumentURL == nil ? "Paste contract text" : "Or paste contract text")
                } footer: {
                    Text("Paste the full PDF text or the relevant clauses. Up to ~30,000 characters; longer documents are truncated.")
                }

                if let err = error {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.subheadline)
                    }
                }

                Section {
                    Button {
                        Task { await runReview() }
                    } label: {
                        if isReviewing {
                            HStack { ProgressView().scaleEffect(0.85); Text("Reviewing…") }
                        } else {
                            Label("Run \(mode.displayName)", systemImage: "wand.and.stars")
                        }
                    }
                    .disabled(isReviewing
                              || contractText.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let r = resultPreview {
                    Section("Result") {
                        Text(r.summary).font(.subheadline)
                        RiskPill(level: r.riskScore)
                        Text(r.riskSummary).font(.caption).foregroundColor(.secondary)
                        Text("\(r.clauses.count) clauses extracted — open the Clauses tab to review them.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("AI Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                // Pre-fill the editor with text extracted from the
                // uploaded PDF if the parent view captured one. Only
                // applies on first open — won't clobber user edits.
                if contractText.isEmpty,
                   let txt = prefillText,
                   !txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    contractText = txt
                }
            }
        }
    }

    private var modeFooter: String {
        switch mode {
        case .lightweight: return "Fast review using Haiku. ~\(ContractReviewService.ReviewMode.lightweight.costNote) per call. Good for first pass."
        case .deep:        return "Deeper analysis using Sonnet. ~\(ContractReviewService.ReviewMode.deep.costNote) per call. Use for high-value or unusual contracts."
        }
    }

    private func runReview() async {
        isReviewing = true
        error = nil
        defer { isReviewing = false }
        do {
            let r = try await ContractReviewService.shared.review(
                contract:     contract,
                contractText: contractText,
                mode:         mode,
                in:           store
            )
            resultPreview = r
            ToastService.shared.success("Review complete — \(r.clauses.count) clauses extracted.")
        } catch let e as ContractReviewService.ReviewError {
            error = e.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Pull text from the contract's already-uploaded document. Lets
    /// the user re-run AI Review later without re-uploading or copy-
    /// pasting — the document lives in Supabase Storage and we just
    /// fetch + PDFKit-extract on demand.
    private func loadFromUploadedDocument(_ storagePath: String) async {
        isLoadingDoc = true
        error = nil
        defer { isLoadingDoc = false }
        do {
            let result = try await ContractDocumentService.shared
                .fetchAndExtractText(storagePath: storagePath)
            if let text = result.extractedText, !text.isEmpty {
                contractText = text
                let pages = result.pageCount.map { " (\($0) pages)" } ?? ""
                ToastService.shared.success("Loaded \(text.count) characters\(pages).")
            } else {
                error = "Couldn't extract text from this PDF — it may be a scan. Use Files → choose a text-based PDF, or paste text manually."
            }
        } catch let e as ContractDocumentService.DocumentError {
            error = e.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: ─────────────────────────────────────────────────────────────
// MARK: - Milestone Edit Sheet
// MARK: ─────────────────────────────────────────────────────────────

struct ContractMilestoneEditSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let contractID: UUID
    var existing: ContractMilestone? = nil

    @State private var title: String = ""
    @State private var description: String = ""
    @State private var milestoneDate: Date = Date()
    @State private var milestoneType: MilestoneType = .paymentDue
    @State private var amountText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Title", text: $title)
                    Picker("Type", selection: $milestoneType) {
                        ForEach(MilestoneType.allCases) { Text($0.displayName).tag($0) }
                    }
                    DatePicker("Date", selection: $milestoneDate, displayedComponents: .date)
                }
                Section("Optional") {
                    TextField("Amount due", text: $amountText)
                        .keyboardType(.decimalPad)
                    TextField("Description", text: $description, axis: .vertical)
                }
            }
            .navigationTitle(existing == nil ? "Add Milestone" : "Edit Milestone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        var m = existing ?? ContractMilestone(
                            contractID:    contractID,
                            title:         title,
                            milestoneDate: milestoneDate,
                            milestoneType: milestoneType
                        )
                        m.title         = title
                        m.description   = description.isEmpty ? nil : description
                        m.milestoneDate = milestoneDate
                        m.milestoneType = milestoneType
                        m.amountDue     = Decimal(string: amountText)
                        store.upsertContractMilestone(m)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .bold()
                }
            }
            .onAppear {
                if let e = existing {
                    title = e.title
                    description = e.description ?? ""
                    milestoneDate = e.milestoneDate
                    milestoneType = e.milestoneType
                    amountText = e.amountDue.map { "\($0)" } ?? ""
                }
            }
        }
    }
}

// MARK: ─────────────────────────────────────────────────────────────
// MARK: - Glossary Sheet
// MARK: ─────────────────────────────────────────────────────────────

/// Pop-up explanation for any contract term, accessible from clause
/// cards. Doubles as a standalone glossary browser when launched
/// from Settings or the contract list toolbar.
struct GlossaryEntrySheet: View {
    let entry: ContractGlossaryEntry
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(entry.term)
                        .font(.title2.weight(.semibold))
                    Text(entry.category.rawValue)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        .foregroundColor(.accentColor)
                    Text(entry.plainEnglish)
                        .font(.body)
                    Divider()
                    Label(entry.whyItMatters, systemImage: "exclamationmark.bubble.fill")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                    if !entry.aliases.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Also called").font(.caption).foregroundColor(.secondary)
                            Text(entry.aliases.joined(separator: " · ")).font(.caption)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.bold()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Browse-all glossary view — surfaces all ~50 entries grouped by
/// category. Reachable from Settings → Help & Reference (or wherever
/// you wire it).
struct ContractGlossaryBrowserView: View {
    @State private var search: String = ""
    private var entries: [ContractGlossaryEntry] {
        ContractGlossary.shared.search(search)
    }
    var body: some View {
        List {
            if search.isEmpty {
                ForEach(ContractGlossary.shared.grouped(), id: \.0) { (cat, items) in
                    Section(cat.rawValue) {
                        ForEach(items) { GlossaryRow(entry: $0) }
                    }
                }
            } else {
                ForEach(entries) { GlossaryRow(entry: $0) }
            }
        }
        .navigationTitle("Contract Glossary")
        .searchable(text: $search, prompt: "Search terms")
    }
}

private struct GlossaryRow: View {
    let entry: ContractGlossaryEntry
    @State private var show = false
    var body: some View {
        Button { show = true } label: {
            HStack {
                Text(entry.term).font(.subheadline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $show) {
            GlossaryEntrySheet(entry: entry)
        }
    }
}

// MARK: ─────────────────────────────────────────────────────────────
// MARK: - Phase 2A: Checklist row, Compliance row, Document upload
// MARK: ─────────────────────────────────────────────────────────────

/// One row on the Checklist tab. Auto-checked items render disabled
/// (green tick, "Auto" badge) so the user can't toggle them off
/// against AI evidence; manual items have a working toggle.
private struct ChecklistItemRow: View {
    let item: ChecklistItem
    let isAutoCheck: Bool
    let isManualCheck: Bool
    let onToggle: () -> Void

    private var isChecked: Bool { isAutoCheck || isManualCheck }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isChecked ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(isAutoCheck)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.label)
                        .font(.subheadline.weight(.semibold))
                        .strikethrough(isChecked, color: .secondary)
                    if isAutoCheck {
                        Text("AUTO")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.18)))
                            .foregroundColor(.green)
                    }
                }
                Text(item.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

/// One compliance-document row on the Compliance tab.
private struct ComplianceRow: View {
    let doc: ComplianceDocument
    let onEdit: () -> Void

    /// Color hierarchy:
    ///   • Requirement-only rows render in orange-warning territory
    ///     because they're an unmet contract demand
    ///   • Held-cert rows: red if expired, orange if expiring < 30d,
    ///     green otherwise
    private var accent: Color {
        if doc.isRequirementOnly { return .orange }
        if doc.isExpired         { return .red }
        if doc.isExpiringSoon    { return .orange }
        return .green
    }

    var body: some View {
        Button(action: onEdit) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: doc.documentType.icon)
                    .foregroundColor(accent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(doc.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Spacer()
                        if doc.isRequirementOnly {
                            // Most prominent — represents unmet demand
                            Label("REQUIRED", systemImage: "exclamationmark.shield.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.orange)
                        } else if doc.isExpired {
                            Label("EXPIRED", systemImage: "exclamationmark.octagon.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.red)
                        } else if doc.isExpiringSoon, let d = doc.daysUntilExpiry {
                            Text("EXPIRES IN \(d)d")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.orange)
                        }
                    }
                    Text(doc.documentType.displayName)
                        .font(.caption).foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        if let carrier = doc.carrier {
                            Text(carrier).font(.caption).foregroundColor(.secondary)
                        }
                        if let policy = doc.policyNumber {
                            Text("· \(policy)").font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        }
                        if let limit = doc.coverageLimit {
                            // For requirement-only rows the coverage_limit
                            // is the MINIMUM the contract demands; we
                            // prefix to make that explicit.
                            let prefix = doc.isRequirementOnly ? "min " : ""
                            Text("· " + prefix + limit.formatted(.currency(code: doc.currency)))
                                .font(.caption.weight(.semibold))
                        }
                    }
                    if doc.isRequirementOnly {
                        Text("Awaiting actual cert from sub/supplier — open to fill in carrier + policy + expiry once received.")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    } else if let expiry = doc.expiryDate {
                        Text("Expires \(Self.df.string(from: expiry))")
                            .font(.caption2)
                            .foregroundColor(accent)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(accent.opacity(
                        doc.isRequirementOnly || doc.isExpired || doc.isExpiringSoon
                            ? 0.4 : 0
                    ), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; return f
    }()
}

/// Single-line "tap to download" row for primary contract documents.
/// Generates a signed URL on demand instead of caching one (signed
/// URLs expire and we don't want to track that on the client).
private struct DocumentLinkRow: View {
    let filename: String
    let storagePath: String
    @State private var isFetching = false
    @State private var error: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Task { await openDocument() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text.fill")
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(filename)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(storagePath)
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if isFetching {
                        ProgressView().scaleEffect(0.85)
                    } else {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.accentColor)
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            if let err = error {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    private func openDocument() async {
        isFetching = true
        error = nil
        defer { isFetching = false }
        do {
            let url = try await ContractDocumentService.shared.signedURL(for: storagePath)
            await UIApplication.shared.open(url)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: ─────────────────────────────────────────────────────────────
// MARK: - Document Upload Sheet (primary contract PDF)
// MARK: ─────────────────────────────────────────────────────────────

import UniformTypeIdentifiers

/// Lets the user pick a PDF / DOCX from Files, uploads it to the
/// contracts bucket, extracts text via PDFKit, and persists the
/// storage path on the contract. If text extraction succeeded, the
/// extracted text is offered as a pre-fill for the AI review sheet.
struct ContractDocumentUploadSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let contract: Contract
    /// Called once we've extracted text from a successful PDF upload —
    /// the parent view caches it for the AI Review sheet's pre-fill.
    /// nil = extraction failed (scanned PDF) or non-PDF file.
    let onTextExtracted: (String?) -> Void

    @State private var picker = false
    @State private var isUploading = false
    @State private var error: String? = nil
    @State private var lastResult: ContractDocumentService.UploadResult? = nil

    init(contract: Contract,
         onTextExtracted: @escaping (String?) -> Void = { _ in }) {
        self.contract        = contract
        self.onTextExtracted = onTextExtracted
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        picker = true
                    } label: {
                        Label("Choose PDF or DOCX", systemImage: "doc.fill.badge.plus")
                    }
                } header: {
                    Text("Upload contract document")
                } footer: {
                    Text("PDFs work best — we extract the text so the AI Review sheet doesn't need copy-paste. Files up to 25MB.")
                }

                if isUploading {
                    Section {
                        HStack {
                            ProgressView().scaleEffect(0.85)
                            Text("Uploading + extracting text…")
                                .font(.subheadline)
                        }
                    }
                }

                if let r = lastResult {
                    Section("Uploaded") {
                        Label(r.filename, systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        if let pages = r.pageCount {
                            Text("\(pages) pages").font(.caption).foregroundColor(.secondary)
                        }
                        if let text = r.extractedText {
                            Text("\(text.count) characters of text extracted — ready for AI review.")
                                .font(.caption).foregroundColor(.secondary)
                        } else {
                            Label("Couldn't extract text — this may be a scanned PDF. AI review will need manual paste.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundColor(.orange)
                        }
                    }
                }

                if let err = error {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Upload Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $picker,
                allowedContentTypes: [
                    .pdf, .init(filenameExtension: "doc")!, .init(filenameExtension: "docx")!
                ],
                allowsMultipleSelection: false
            ) { result in
                Task { await handlePick(result) }
            }
        }
    }

    private func handlePick(_ result: Result<[URL], Error>) async {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            // SecurityScopedResource: required when reading a file the
            // user picked from Files / iCloud Drive.
            let didStartScope = url.startAccessingSecurityScopedResource()
            defer { if didStartScope { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)

            isUploading = true
            error = nil
            let res = try await ContractDocumentService.shared.upload(
                data: data,
                filename: url.lastPathComponent,
                contractID: contract.id,
                in: store
            )
            lastResult = res

            // Persist on the contract.
            var updated = contract
            updated.primaryDocumentURL  = res.storagePath
            updated.primaryDocumentName = res.filename
            store.upsertContract(updated)
            // Bubble extracted text up to the parent view so the next
            // AI Review pops up with text already filled — no copy-paste.
            onTextExtracted(res.extractedText)
            ToastService.shared.success(
                res.extractedText != nil
                    ? "Uploaded — text extracted, AI Review is ready."
                    : "Uploaded — couldn't auto-extract text. AI Review needs manual paste."
            )
        } catch let e as ContractDocumentService.DocumentError {
            error = e.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
        isUploading = false
    }
}

// MARK: ─────────────────────────────────────────────────────────────
// MARK: - Compliance Document Edit Sheet
// MARK: ─────────────────────────────────────────────────────────────

/// Form for adding / editing one insurance certificate or surety bond.
/// On save, the iOS-side store auto-creates two milestones (warning
/// 30 days out + on-day expiry pin) so the Schedule tab surfaces
/// the renewal automatically.
struct ComplianceDocumentEditSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let contractID: UUID
    let existing: ComplianceDocument?

    @State private var kind: ComplianceKind = .insurance
    @State private var documentType: ComplianceDocumentType = .generalLiability
    @State private var title: String = ""
    @State private var carrier: String = ""
    @State private var policyNumber: String = ""
    @State private var namedInsured: String = ""
    @State private var coverageLimitText: String = ""
    @State private var aggregateLimitText: String = ""
    @State private var deductibleText: String = ""
    @State private var currency: String = "USD"
    @State private var effectiveDate: Date? = nil
    /// Expiry is OPTIONAL because requirement-only rows have no actual
    /// cert yet (the contract just demands one). When the user later
    /// receives the cert, they fill this in + flip `isRequirementOnly`
    /// to false.
    @State private var expiryDate: Date? = Calendar.current.date(byAdding: .year, value: 1, to: Date())
    @State private var isRequirementOnly: Bool = false
    @State private var notes: String = ""

    @State private var showFilePicker = false
    @State private var isUploading = false
    @State private var uploadError: String? = nil
    @State private var uploadedPath: String? = nil
    @State private var uploadedFilename: String? = nil

    private var typesForKind: [ComplianceDocumentType] {
        ComplianceDocumentType.allCases.filter { $0.kind == kind }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Document type") {
                    Picker("Kind", selection: $kind) {
                        Text("Insurance").tag(ComplianceKind.insurance)
                        Text("Bond").tag(ComplianceKind.bond)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: kind) { _, newKind in
                        if !typesForKind.contains(documentType) {
                            documentType = typesForKind.first ?? .other
                        }
                    }
                    Picker("Type", selection: $documentType) {
                        ForEach(typesForKind) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    Text(documentType.helperText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Identity") {
                    TextField("Title", text: $title)
                    TextField("Carrier / Surety", text: $carrier)
                    TextField("Policy / Bond number", text: $policyNumber)
                    TextField("Named insured", text: $namedInsured)
                }

                Section("Limits") {
                    TextField("Coverage / face value", text: $coverageLimitText)
                        .keyboardType(.decimalPad)
                    TextField("Aggregate limit", text: $aggregateLimitText)
                        .keyboardType(.decimalPad)
                    TextField("Deductible", text: $deductibleText)
                        .keyboardType(.decimalPad)
                    TextField("Currency", text: $currency)
                }

                Section {
                    Toggle("Requirement only (no cert yet)",
                           isOn: $isRequirementOnly)
                } footer: {
                    Text(isRequirementOnly
                        ? "This row records what the contract REQUIRES, not a cert you currently hold. No expiry until you receive the actual document — toggle this off + fill in expiry when it arrives."
                        : "This row tracks an actual cert you hold. Expiry triggers auto-milestones on the Schedule (30-day warning + on-day pin).")
                }

                Section("Dates") {
                    OptionalDateField(label: "Effective", date: $effectiveDate)
                    if isRequirementOnly {
                        Text("Expiry: not yet — waiting on actual cert.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        OptionalDateField(label: "Expires", date: $expiryDate)
                    }
                }

                Section {
                    if let path = uploadedPath, let name = uploadedFilename {
                        Label(name, systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(path).font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    }
                    Button {
                        showFilePicker = true
                    } label: {
                        if isUploading {
                            HStack { ProgressView().scaleEffect(0.85); Text("Uploading…") }
                        } else {
                            Label(uploadedPath == nil ? "Attach PDF" : "Replace PDF",
                                  systemImage: "doc.fill.badge.plus")
                        }
                    }
                    .disabled(isUploading)
                    if let err = uploadError {
                        Text(err).foregroundColor(.red).font(.caption)
                    }
                } header: {
                    Text("Document file (optional)")
                } footer: {
                    Text("Attach the PDF / scan of the certificate or bond. Optional — you can add it later.")
                }

                Section("Notes") {
                    TextEditor(text: $notes).frame(minHeight: 80)
                }

                if let e = existing {
                    Section {
                        Button(role: .destructive) {
                            store.deleteComplianceDocument(e)
                            dismiss()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Compliance Doc" : "Edit Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                        .bold()
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.pdf, .image],
                allowsMultipleSelection: false
            ) { result in
                Task { await handleFilePick(result) }
            }
            .onAppear { populateFromExisting() }
        }
    }

    // MARK: behavior

    private func populateFromExisting() {
        guard let e = existing else { return }
        kind               = e.kind
        documentType       = e.documentType
        title              = e.title
        carrier            = e.carrier ?? ""
        policyNumber       = e.policyNumber ?? ""
        namedInsured       = e.namedInsured ?? ""
        coverageLimitText  = e.coverageLimit.map { "\($0)" } ?? ""
        aggregateLimitText = e.aggregateLimit.map { "\($0)" } ?? ""
        deductibleText     = e.deductible.map { "\($0)" } ?? ""
        currency           = e.currency
        effectiveDate      = e.effectiveDate
        expiryDate         = e.expiryDate
        isRequirementOnly  = e.isRequirementOnly
        notes              = e.notes ?? ""
        uploadedPath       = e.documentURL
        uploadedFilename   = e.documentFilename
    }

    private func handleFilePick(_ result: Result<[URL], Error>) async {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)

            isUploading = true
            uploadError = nil
            let docID = existing?.id ?? UUID()
            let res = try await ContractDocumentService.shared.uploadComplianceDocument(
                data: data, filename: url.lastPathComponent,
                documentID: docID, in: store
            )
            uploadedPath = res.storagePath
            uploadedFilename = res.filename
        } catch let e as ContractDocumentService.DocumentError {
            uploadError = e.errorDescription
        } catch {
            uploadError = error.localizedDescription
        }
        isUploading = false
    }

    private func save() {
        var d = existing ?? ComplianceDocument(
            kind:         kind,
            documentType: documentType,
            title:        title
        )
        d.contractID       = contractID
        d.kind             = kind
        d.documentType     = documentType
        d.title            = title
        d.carrier          = carrier.isEmpty ? nil : carrier
        d.policyNumber     = policyNumber.isEmpty ? nil : policyNumber
        d.namedInsured     = namedInsured.isEmpty ? nil : namedInsured
        d.coverageLimit    = Decimal(string: coverageLimitText)
        d.aggregateLimit   = Decimal(string: aggregateLimitText)
        d.deductible       = Decimal(string: deductibleText)
        d.currency         = currency.isEmpty ? "USD" : currency
        d.effectiveDate    = effectiveDate
        // Requirement-only rows have no cert yet, so no expiry. The
        // store's auto-milestone synthesis already skips when expiry
        // is nil, so we don't need to also clear the date — but doing
        // so keeps the data clean and the UI accurate.
        d.expiryDate         = isRequirementOnly ? nil : expiryDate
        d.isRequirementOnly  = isRequirementOnly
        d.documentURL      = uploadedPath ?? d.documentURL
        d.documentFilename = uploadedFilename ?? d.documentFilename
        d.notes            = notes.isEmpty ? nil : notes
        d.uploadedBy       = store.currentUser?.id ?? d.uploadedBy
        store.upsertComplianceDocument(d)
        dismiss()
    }
}

// MARK: ─────────────────────────────────────────────────────────────
// MARK: - Phase 2B: Lien Waiver UI
// MARK: ─────────────────────────────────────────────────────────────

/// Compact lien waiver row — color-coded by lifecycle status.
struct LienWaiverRow: View {
    let waiver: LienWaiver
    let onTap: () -> Void

    private var accentColor: Color {
        switch waiver.status {
        case .received:  return .green
        case .sent, .pending: return .blue
        case .rejected, .expired: return .red
        case .replaced:  return .secondary
        case .requested: return .orange
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: waiver.isConditional ? "checkmark.shield" : "exclamationmark.shield.fill")
                        .foregroundColor(waiver.isConditional ? .green : .orange)
                    Text(waiver.waiverType.displayName)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(waiver.status.displayName.uppercased())
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(accentColor.opacity(0.18)))
                        .foregroundColor(accentColor)
                }
                HStack(spacing: 8) {
                    Text(waiver.waiverFromName)
                        .font(.caption).foregroundColor(.secondary)
                    if let amount = waiver.amount {
                        Text("· " + amount.formatted(.currency(code: waiver.currency)))
                            .font(.caption.weight(.semibold))
                    }
                    if let through = waiver.throughDate {
                        Text("· through " + Self.df.string(from: through))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
                if let signed = waiver.signedAt {
                    Label("Signed " + Self.df.string(from: signed),
                          systemImage: "signature")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else if waiver.magicLinkToken != nil,
                          waiver.magicLinkRevokedAt == nil {
                    // Pending magic-link signature — show a blue pill so
                    // the user knows we're waiting on the sub.
                    Label("Awaiting digital signature",
                          systemImage: "envelope.badge.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.blue)
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; return f
    }()
}

/// Form to create / edit a single lien waiver. Captures who's
/// waiving, type, amount, through date. Phase 2B-1 doesn't include
/// the magic-link send flow yet (it'll mirror contract-accept) —
/// that's phase 2B-2. For now manual paper-trail capture.
struct LienWaiverEditSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let contractID: UUID
    let existing: LienWaiver?

    @State private var waiverType: LienWaiverType = .progressConditional
    @State private var status:     LienWaiverStatus = .requested
    @State private var fromName:   String = ""
    @State private var fromEmail:  String = ""
    @State private var amountText: String = ""
    @State private var retainageText: String = ""
    @State private var throughDate: Date? = nil
    @State private var paymentRef: String = ""
    @State private var notes:      String = ""
    @State private var signedByName:  String = ""
    @State private var signedByEmail: String = ""

    // Magic-link sign-off state
    @State private var signStatus: LienWaiverAcceptanceService.SignStatus? = nil
    @State private var pendingSignURL: URL? = nil
    @State private var showShareSheet  = false
    @State private var showRevokeConfirm = false
    @State private var isMinting = false
    /// Phase-2 deferred audit fix: PDF generation state.
    @State private var isGeneratingPDF = false
    @State private var pdfShareURL: URL? = nil
    @State private var showPDFShareSheet = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Waiver type") {
                    Picker("Type", selection: $waiverType) {
                        ForEach(LienWaiverType.allCases) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    Text(waiverType.helperText)
                        .font(.caption).foregroundColor(.secondary)
                    HStack {
                        Text("Risk to signer")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(waiverType.signerRiskLevel.displayName.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(riskColor(waiverType.signerRiskLevel))
                    }
                }

                Section("Waiving party") {
                    TextField("Sub / supplier name", text: $fromName)
                    TextField("Email (for digital sign)", text: $fromEmail)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                }

                Section("Amounts") {
                    TextField("Amount paid (or being paid)", text: $amountText)
                        .keyboardType(.decimalPad)
                    TextField("Retainage excluded from waiver", text: $retainageText)
                        .keyboardType(.decimalPad)
                    OptionalDateField(label: "Through date", date: $throughDate)
                    TextField("Payment ref (check #, ACH ref)", text: $paymentRef)
                }

                Section("Lifecycle") {
                    Picker("Status", selection: $status) {
                        ForEach(LienWaiverStatus.allCases, id: \.self) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                }

                if status == .received {
                    Section("Captured signature") {
                        TextField("Signed by (name)", text: $signedByName)
                        TextField("Signed by (email)", text: $signedByEmail)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                    }
                }

                Section("Notes") {
                    TextEditor(text: $notes).frame(minHeight: 80)
                }

                // Phase-2 deferred audit fix: PDF generator. Available
                // on existing waivers regardless of signed status — a
                // signed waiver gets the typed name + date stamped on
                // the signature line; an unsigned one renders empty
                // signature fields ready to print + sign by hand.
                // Uploads to the `contracts` bucket on tap and stamps
                // documentURL so the PDF survives across devices.
                if let e = existing {
                    Section {
                        Button {
                            Task { await generatePDF(for: e) }
                        } label: {
                            HStack {
                                if isGeneratingPDF {
                                    ProgressView().scaleEffect(0.85)
                                    Text("Generating PDF…")
                                } else {
                                    Label(e.documentURL == nil
                                          ? "Generate PDF"
                                          : "Re-generate PDF",
                                          systemImage: "doc.text.fill")
                                }
                            }
                        }
                        .disabled(isGeneratingPDF)
                    } footer: {
                        if e.documentURL != nil {
                            Text("PDF on file. Re-generating overwrites the stored copy with the latest waiver state.")
                        } else {
                            Text("Renders the waiver to a PDF and uploads it to your company's contracts storage. The PDF includes the full statutory language for the chosen waiver type.")
                        }
                    }
                }

                // Magic-link digital sign-off — only on existing waivers
                // (token needs a row to be attached to). Hidden when the
                // waiver has already been signed; revoke option appears
                // when there's a live unrevoked link.
                if let e = existing, e.signedAt == nil,
                   store.currentUserRole.isAdmin {
                    Section {
                        if let s = signStatus, s.hasToken, s.signedAt == nil, s.revokedAt == nil {
                            Label(s.displaySummary, systemImage: "envelope.badge.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.blue)
                        }
                        Button {
                            Task { await mintSignLink(for: e.id) }
                        } label: {
                            if isMinting {
                                HStack { ProgressView().scaleEffect(0.85); Text("Minting link…") }
                            } else {
                                Label(signStatus?.hasToken == true && signStatus?.signedAt == nil
                                      ? "Replace sign-off link"
                                      : "Send for digital signature",
                                      systemImage: "signature")
                            }
                        }
                        .disabled(isMinting)
                        if signStatus?.hasToken == true,
                           signStatus?.signedAt == nil,
                           signStatus?.revokedAt == nil {
                            Button(role: .destructive) {
                                showRevokeConfirm = true
                            } label: {
                                Label("Revoke link", systemImage: "xmark.circle")
                            }
                        }
                    } header: {
                        Text("Digital signature")
                    } footer: {
                        Text("Mints a one-time URL for the sub or supplier to sign electronically. Their browser shows the waiver terms with plain-English risk language before they sign. Audited.")
                    }
                }

                if let e = existing {
                    Section {
                        Button(role: .destructive) {
                            store.deleteLienWaiver(e)
                            dismiss()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Lien Waiver" : "Edit Waiver")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }
                        .disabled(fromName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .bold()
                }
            }
            .onAppear { populate() }
            .sheet(isPresented: $showShareSheet) {
                if let url = pendingSignURL {
                    ShareSheet(items: [url.absoluteString])
                }
            }
            .alert("Revoke sign-off link?", isPresented: $showRevokeConfirm) {
                Button("Revoke", role: .destructive) {
                    Task { await revokeSignLink() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The signer's link will stop working immediately. You can mint a new one any time.")
            }
            .task(id: existing?.id) {
                guard let e = existing else { return }
                signStatus = try? await LienWaiverAcceptanceService.shared.fetchStatus(waiverID: e.id)
            }
        }
    }

    // MARK: - Sign-off actions

    /// Mint a sign-off magic link and either:
    ///   • auto-email it to `waiver.waiverFromEmail` when set, or
    ///   • fall back to the share sheet so the operator can route the link
    ///     through email / SMS / messages manually (matches the legacy
    ///     behavior; preserves usability when no email is on file).
    /// Mirrors the BulkLienWaiverService.sendOne pattern — same body /
    /// subject helpers would be ideal here once we extract them.
    private func mintSignLink(for waiverID: UUID) async {
        isMinting = true
        defer { isMinting = false }
        do {
            let result = try await LienWaiverAcceptanceService.shared.mintToken(waiverID: waiverID)
            pendingSignURL = result.url
            // Refresh local status after the mint.
            signStatus = try? await LienWaiverAcceptanceService.shared.fetchStatus(waiverID: waiverID)

            // Auto-email when a recipient email is on file. The address comes
            // from waiverFromEmail (the party signing the waiver). Falls
            // through to the share sheet on missing/blank email so we don't
            // surprise an operator who's used to sharing via SMS.
            let recipient = waiverFromEmail(for: waiverID)
            if let email = recipient {
                let mailResult = await EmailService.shared.sendText(
                    to:         [email],
                    subject:    acknowledgmentEmailSubject(),
                    bodyText:   acknowledgmentEmailBody(url: result.url),
                    entityType: "lien_waiver",
                    entityID:   waiverID
                )
                switch mailResult {
                case .success:
                    ToastService.shared.success("Acknowledgment link emailed to \(email).")
                case .failure(let err):
                    // Email failed — still surface the share sheet so the
                    // operator can deliver the link out-of-band.
                    showShareSheet = true
                    ToastService.shared.error("Couldn't email link: \(err.userMessage). Share manually.")
                }
            } else {
                showShareSheet = true
                ToastService.shared.success("Sign-off link minted — share via email or SMS.")
            }
        } catch let err as LienWaiverAcceptanceService.AcceptanceError {
            ToastService.shared.error(err.errorDescription ?? "Couldn't mint link")
        } catch {
            ToastService.shared.error(error.localizedDescription)
        }
    }

    /// Resolve the email address to send the acknowledgment link to.
    /// Reads from the persisted waiver row rather than the local form state
    /// so a freshly-saved row's email is honored even if the editor was
    /// dismissed/reopened.
    private func waiverFromEmail(for waiverID: UUID) -> String? {
        // Persisted row first, form state as fallback (covers a fresh waiver
        // whose email hasn't synced through the local store yet).
        let raw = store.lienWaivers.first { $0.id == waiverID }?.waiverFromEmail
            ?? signedByEmail
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func acknowledgmentEmailSubject() -> String {
        let company = AppSettings.shared.companyName.isEmpty
            ? "Aski IQ"
            : AppSettings.shared.companyName
        return "Lien waiver acknowledgment request — \(company)"
    }

    private func acknowledgmentEmailBody(url: URL) -> String {
        let signer = AppSettings.shared.companyName.isEmpty
            ? "Aski IQ"
            : AppSettings.shared.companyName
        return """
        Hello,

        Please review and sign the lien waiver acknowledgment using the secure link below:

        \(url.absoluteString)

        This link is unique to you and will expire after 30 days. Reply to this email if you have any questions.

        Thanks,
        \(signer)
        """
    }

    private func revokeSignLink() async {
        guard let e = existing else { return }
        do {
            try await LienWaiverAcceptanceService.shared.revoke(waiverID: e.id)
            signStatus = try? await LienWaiverAcceptanceService.shared.fetchStatus(waiverID: e.id)
            ToastService.shared.warning("Sign-off link revoked.")
        } catch {
            ToastService.shared.error("Couldn't revoke: \(error.localizedDescription)")
        }
    }

    /// Phase-2 deferred audit fix: render the waiver to a PDF +
    /// upload to the `contracts` storage bucket, then stamp
    /// `documentURL` on the row so other devices pick it up. Failure
    /// keeps the row clean — just toasts the error.
    private func generatePDF(for waiver: LienWaiver) async {
        isGeneratingPDF = true
        defer { isGeneratingPDF = false }
        do {
            let path = try await LienWaiverDocumentService.shared.generateAndUpload(
                waiver:         waiver,
                companyName:    AppSettings.shared.companyName,
                companyAddress: AppSettings.shared.companyAddress.isEmpty
                    ? nil
                    : AppSettings.shared.companyAddress
            )
            // Stamp documentURL on the local row + push.
            if var w = store.lienWaivers.first(where: { $0.id == waiver.id }) {
                w.documentURL = path
                w.documentFilename = "lien-waiver-\(waiver.id.uuidString.prefix(8)).pdf"
                w.syncStatus = .pending
                w.updatedAt  = Date()
                store.upsertLienWaiver(w)
            }
            ToastService.shared.success("Waiver PDF saved to your contracts storage.")
        } catch {
            ToastService.shared.error("Couldn't generate PDF: \(error.localizedDescription)")
        }
    }

    private func populate() {
        guard let e = existing else { return }
        waiverType    = e.waiverType
        status        = e.status
        fromName      = e.waiverFromName
        fromEmail     = e.waiverFromEmail ?? ""
        amountText    = e.amount.map { "\($0)" } ?? ""
        retainageText = e.retainageExcluded.map { "\($0)" } ?? ""
        throughDate   = e.throughDate
        paymentRef    = e.paymentReference ?? ""
        notes         = e.notes ?? ""
        signedByName  = e.signedByName ?? ""
        signedByEmail = e.signedByEmail ?? ""
    }

    private func save() {
        var w = existing ?? LienWaiver(
            waiverType:     waiverType,
            waiverFromName: fromName
        )
        w.contractID        = contractID
        w.waiverType        = waiverType
        w.status            = status
        w.waiverFromName    = fromName
        w.waiverFromEmail   = fromEmail.isEmpty ? nil : fromEmail
        w.amount            = Decimal(string: amountText)
        w.retainageExcluded = Decimal(string: retainageText)
        w.throughDate       = throughDate
        w.paymentReference  = paymentRef.isEmpty ? nil : paymentRef
        w.notes             = notes.isEmpty ? nil : notes
        if status == .received {
            w.receivedAt    = Date()
            w.signedByName  = signedByName.isEmpty ? nil : signedByName
            w.signedByEmail = signedByEmail.isEmpty ? nil : signedByEmail
            if w.signedAt == nil { w.signedAt = Date() }
        }
        w.createdBy = w.createdBy ?? store.currentUser?.id
        store.upsertLienWaiver(w)
        dismiss()
    }

    private func riskColor(_ level: RiskLevel) -> Color {
        switch level {
        case .low:      return .green
        case .medium:   return .yellow
        case .high:     return .orange
        case .critical: return .red
        }
    }
}

// MARK: - Contract sign-off pill (renders on detail header)

/// Small status pill that renders next to the contract header showing
/// the current sign-off state. Hidden when no token has been minted.
/// Stays in sync via a simple `.task` re-fetch on appear.
struct ContractSignOffPill: View {
    let contractID: UUID
    @State private var status: ContractAcceptanceService.AcceptanceStatus? = nil

    var body: some View {
        Group {
            if let s = status, s.hasToken {
                Label(s.displaySummary,
                      systemImage: s.acceptedAt != nil
                        ? "checkmark.seal.fill"
                        : (s.revokedAt != nil ? "xmark.circle.fill" : "envelope.badge.fill"))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(
                        s.acceptedAt != nil ? .green :
                        (s.revokedAt != nil ? .secondary : .blue)
                    )
            } else {
                EmptyView()
            }
        }
        .task(id: contractID) {
            status = try? await ContractAcceptanceService.shared.fetchStatus(contractID: contractID)
        }
    }
}

// MARK: ─────────────────────────────────────────────────────────────
// MARK: - Phase 2D: AI Contract Diff Sheet
// MARK: ─────────────────────────────────────────────────────────────

/// Paste old + new contract text. Run an AI diff. Get a structured
/// report of what materially changed, color-coded by impact.
///
/// USE CASE
/// Sub or supplier returns a marked-up version. PM pastes both sides,
/// taps Run. Three minutes later: a card-by-card list of every
/// material change with plain-English explanations + risk impact.
struct ContractDiffSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let contract: Contract
    /// Optional pre-fill — the parent view passes the most recently
    /// uploaded primary document text as the OLD baseline so the user
    /// only needs to paste the marked-up redline.
    let prefillOldText: String?

    @State private var oldText: String = ""
    @State private var newText: String = ""
    @State private var mode: ContractDiffService.DiffMode = .deep
    @State private var isRunning = false
    @State private var error: String? = nil
    @State private var result: ContractDiffService.DiffResult? = nil
    /// While downloading + extracting text from the contract's stored
    /// document into the OLD field. Disables Run during the fetch.
    @State private var isLoadingDoc = false

    init(contract: Contract, prefillOldText: String? = nil) {
        self.contract       = contract
        self.prefillOldText = prefillOldText
    }

    var body: some View {
        NavigationStack {
            Form {
                if let r = result {
                    resultSections(r)
                } else {
                    inputSections
                }
            }
            .navigationTitle("AI Diff")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
                if result != nil {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("New Diff") {
                            result = nil
                            error = nil
                        }
                    }
                }
            }
            .onAppear {
                if oldText.isEmpty,
                   let txt = prefillOldText,
                   !txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    oldText = txt
                }
            }
        }
    }

    // MARK: - Input sections

    @ViewBuilder
    private var inputSections: some View {
        Section {
            Picker("Depth", selection: $mode) {
                Text(ContractDiffService.DiffMode.lightweight.displayName)
                    .tag(ContractDiffService.DiffMode.lightweight)
                Text(ContractDiffService.DiffMode.deep.displayName)
                    .tag(ContractDiffService.DiffMode.deep)
            }
            .pickerStyle(.segmented)
            Text(modeFooter)
                .font(.caption).foregroundColor(.secondary)
        }

        // ── Load from uploaded PDF (OLD baseline) ─────────────────
        // When the contract has a primary document attached, offer a
        // one-tap "Load OLD from uploaded PDF". The diff use case is
        // typically: "we last sent THIS, and the sub returned a
        // marked-up version" — so the OLD field is the prior agreed
        // text, which is exactly what the contract's primary document
        // contains.
        if let path = contract.primaryDocumentURL {
            Section {
                Button {
                    Task { await loadOldFromUploadedDocument(path) }
                } label: {
                    HStack {
                        if isLoadingDoc {
                            ProgressView().scaleEffect(0.85)
                            Text("Extracting OLD from PDF…")
                        } else {
                            Image(systemName: "doc.text.fill")
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Load OLD from uploaded PDF")
                                    .font(.subheadline.weight(.semibold))
                                Text(contract.primaryDocumentName ?? path)
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                }
                .disabled(isLoadingDoc)
            } footer: {
                Text("Use the contract's stored PDF as the OLD baseline. Then paste the counterparty's redline in the New version below.")
            }
        }

        Section {
            TextEditor(text: $oldText)
                .frame(minHeight: 140)
                .font(.system(.body, design: .monospaced))
                .disabled(isLoadingDoc)
        } header: {
            Text("Old version (last agreed)")
        } footer: {
            Text(prefillOldText != nil
                 ? "Pre-filled from the uploaded contract. Paste the redline below in the New version."
                 : "Paste the previously-agreed text, last sent draft, or use Load from PDF above. Up to 15,000 characters; longer is truncated.")
        }

        Section {
            TextEditor(text: $newText)
                .frame(minHeight: 140)
                .font(.system(.body, design: .monospaced))
        } header: {
            Text("New version (returned redline)")
        } footer: {
            Text("Paste the counterparty's marked-up version or new proposal.")
        }

        if let err = error {
            Section {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .font(.subheadline)
            }
        }

        Section {
            Button {
                Task { await runDiff() }
            } label: {
                if isRunning {
                    HStack { ProgressView().scaleEffect(0.85); Text("Diffing…") }
                } else {
                    Label("Run \(mode.displayName)", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(isRunning
                      || oldText.trimmingCharacters(in: .whitespaces).isEmpty
                      || newText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - Result sections

    @ViewBuilder
    private func resultSections(_ r: ContractDiffService.DiffResult) -> some View {
        Section {
            HStack {
                Text(r.summary)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                RiskDeltaPill(delta: r.riskDelta)
            }
        } header: {
            Text("Summary")
        }

        if r.changes.isEmpty {
            Section {
                Label("No material changes detected.", systemImage: "checkmark.seal")
                    .foregroundColor(.green)
                    .font(.subheadline)
            }
        } else {
            Section("Material changes (\(r.changes.count))") {
                ForEach(Array(r.changes.enumerated()), id: \.offset) { _, change in
                    DiffChangeCard(change: change)
                        .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
                }
            }
        }
    }

    private var modeFooter: String {
        switch mode {
        case .lightweight:
            return "Fast diff using Haiku. ~\(ContractDiffService.DiffMode.lightweight.costNote) per call. Use for trivial revisions."
        case .deep:
            return "Deep diff using Sonnet — catches subtle word swaps. ~\(ContractDiffService.DiffMode.deep.costNote) per call. Default for negotiation."
        }
    }

    private func runDiff() async {
        isRunning = true
        error = nil
        defer { isRunning = false }
        do {
            let r = try await ContractDiffService.shared.diff(
                contract: contract,
                oldText:  oldText,
                newText:  newText,
                mode:     mode
            )
            result = r
            ToastService.shared.success("Diff complete — \(r.changes.count) material changes.")
        } catch let e as ContractDiffService.DiffError {
            error = e.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Pull text from the contract's already-uploaded primary document
    /// into the OLD field. Mirrors the same helper on AI Review — the
    /// extraction happens in `ContractDocumentService` so both sheets
    /// share the implementation.
    private func loadOldFromUploadedDocument(_ storagePath: String) async {
        isLoadingDoc = true
        error = nil
        defer { isLoadingDoc = false }
        do {
            let r = try await ContractDocumentService.shared
                .fetchAndExtractText(storagePath: storagePath)
            if let text = r.extractedText, !text.isEmpty {
                oldText = text
                let pages = r.pageCount.map { " (\($0) pages)" } ?? ""
                ToastService.shared.success("Loaded OLD: \(text.count) characters\(pages).")
            } else {
                error = "Couldn't extract text from this PDF — it may be a scan. Paste the OLD text manually."
            }
        } catch let e as ContractDocumentService.DocumentError {
            error = e.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Diff result subviews

private struct RiskDeltaPill: View {
    let delta: ContractDiffService.RiskDelta
    var body: some View {
        Label(delta.displayName, systemImage: icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundColor(color)
    }
    private var color: Color {
        switch delta {
        case .improved:    return .green
        case .unchanged:   return .secondary
        case .degraded:    return .orange
        case .majorShift:  return .red
        }
    }
    private var icon: String {
        switch delta {
        case .improved:    return "arrow.up.circle.fill"
        case .unchanged:   return "equal.circle.fill"
        case .degraded:    return "arrow.down.circle.fill"
        case .majorShift:  return "exclamationmark.triangle.fill"
        }
    }
}

private struct DiffChangeCard: View {
    let change: ContractDiffService.DiffChange

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ChangeKindBadge(kind: change.kind)
                Text(change.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                RiskPill(level: change.impact)
            }

            if let kind = change.clauseKind {
                Label(kind.displayName, systemImage: "doc.badge.gearshape")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Text(change.explanation)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            if let note = change.impactNote {
                Label(note, systemImage: "exclamationmark.bubble")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if change.oldText != nil || change.newText != nil {
                DisclosureGroup("Show before / after") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let old = change.oldText {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("OLD")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundColor(.red)
                                Text(old)
                                    .font(.system(.caption, design: .monospaced))
                                    .strikethrough()
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        if let new = change.newText {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("NEW")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundColor(.green)
                                Text(new)
                                    .font(.system(.caption, design: .monospaced))
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ChangeKindBadge: View {
    let kind: ContractDiffService.DiffChangeKind
    var body: some View {
        Text(kind.displayName.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundColor(color)
    }
    private var color: Color {
        switch kind {
        case .added:    return .green
        case .removed:  return .red
        case .modified: return .orange
        }
    }
}

// MARK: ─────────────────────────────────────────────────────────────
// MARK: - Phase 2E: Bulk Lien Waiver Request Sheet
// MARK: ─────────────────────────────────────────────────────────────

/// Pick N subs/suppliers, set common waiver terms once, fill per-row
/// amounts, hit "Create + Send" — the service mints magic links for
/// each recipient and emails them. Returns a per-recipient result
/// summary so partial successes are visible.
struct BulkLienWaiverSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let contract: Contract

    // Selection state — keyed by recipient id.
    @State private var selected: Set<UUID> = []
    @State private var amounts:  [UUID: String] = [:]   // text input per row

    // Common waiver fields.
    @State private var waiverType: LienWaiverType = .progressConditional
    @State private var throughDate: Date? = nil
    @State private var paymentRef: String = ""
    @State private var currency: String = "USD"

    // Run state.
    @State private var isSending = false
    @State private var results: [BulkLienWaiverService.RecipientResult] = []
    @State private var error: String? = nil

    /// Recipients pulled live from subcontractors + suppliers,
    /// alphabetized for predictable ordering.
    private var recipients: [BulkLienWaiverService.Recipient] {
        let subs = store.subcontractors
            .filter { !$0.isDeleted && $0.status == .active }
            .map { BulkLienWaiverService.Recipient.from($0) }
        let suppliers = store.suppliers
            .filter { !$0.isDeleted }
            .map { BulkLienWaiverService.Recipient.from($0) }
        return (subs + suppliers).sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !results.isEmpty {
                    resultsList
                } else if recipients.isEmpty {
                    emptyState
                } else {
                    formBody
                }
            }
            .navigationTitle("Bulk Waiver Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(results.isEmpty ? "Cancel" : "Done") { dismiss() }
                }
                if results.isEmpty, !recipients.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            Task { await runBulkSend() }
                        } label: {
                            if isSending {
                                ProgressView().scaleEffect(0.85)
                            } else {
                                Text("Send (\(selected.count))").bold()
                            }
                        }
                        .disabled(isSending || selected.isEmpty)
                    }
                }
            }
        }
    }

    // MARK: - Sub-views

    private var emptyState: some View {
        ContentUnavailableView(
            "No subs or suppliers on file",
            systemImage: "person.2.slash",
            description: Text("Add a subcontractor or supplier first, then return to send waivers in bulk.")
        )
    }

    private var formBody: some View {
        Form {
            Section("Common terms") {
                Picker("Waiver type", selection: $waiverType) {
                    ForEach(LienWaiverType.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                Text(waiverType.helperText)
                    .font(.caption).foregroundColor(.secondary)

                OptionalDateField(label: "Through date", date: $throughDate)
                TextField("Payment reference (check #, ACH ref)", text: $paymentRef)
                TextField("Currency", text: $currency)
            }

            if let err = error {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.subheadline)
                }
            }

            Section {
                ForEach(recipients) { r in
                    BulkRecipientRow(
                        recipient: r,
                        isSelected: selected.contains(r.id),
                        amountText: Binding(
                            get: { amounts[r.id] ?? "" },
                            set: { amounts[r.id] = $0 }
                        ),
                        onToggle: { toggle(r.id) }
                    )
                }
            } header: {
                HStack {
                    Text("Recipients (\(recipients.count))")
                    Spacer()
                    Button(allSelected ? "None" : "All") {
                        if allSelected { selected.removeAll() }
                        else           { selected = Set(recipients.filter { $0.hasEmail }.map { $0.id }) }
                    }
                    .font(.caption.weight(.semibold))
                }
            } footer: {
                Text("Subs/suppliers without an email on file are skipped automatically. Set their email on the contact record first.")
            }
        }
    }

    private var resultsList: some View {
        Form {
            Section {
                ResultsSummaryHeader(results: results)
            }
            Section("Per-recipient outcomes") {
                ForEach(results) { r in
                    BulkResultRow(result: r)
                }
            }
        }
    }

    // MARK: - Behavior

    private var allSelected: Bool {
        let withEmail = recipients.filter { $0.hasEmail }
        return !withEmail.isEmpty && Set(withEmail.map { $0.id }).isSubset(of: selected)
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) }
        else                      { selected.insert(id) }
    }

    private func runBulkSend() async {
        isSending = true
        error = nil
        defer { isSending = false }

        // Build the input array preserving recipient order.
        let picked: [(BulkLienWaiverService.Recipient, amount: Decimal?)] = recipients
            .filter { selected.contains($0.id) }
            .map { r in (r, Decimal(string: amounts[r.id] ?? "")) }

        let common = BulkLienWaiverService.CommonParams(
            contractID:       contract.id,
            waiverType:       waiverType,
            throughDate:      throughDate,
            paymentReference: paymentRef.isEmpty ? nil : paymentRef,
            currency:         currency.isEmpty ? "USD" : currency
        )

        do {
            let out = try await BulkLienWaiverService.shared.sendBulk(
                recipients: picked,
                common:     common,
                in:         store
            )
            results = out

            // Toast summary.
            let okCount = out.filter {
                if case .success = $0.outcome { return true } else { return false }
            }.count
            let total = out.count
            ToastService.shared.success("Sent \(okCount) of \(total) waiver requests.")
        } catch let e as BulkLienWaiverService.BulkError {
            error = e.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Bulk row + result subviews

private struct BulkRecipientRow: View {
    let recipient: BulkLienWaiverService.Recipient
    let isSelected: Bool
    @Binding var amountText: String
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(!recipient.hasEmail)

            VStack(alignment: .leading, spacing: 2) {
                Text(recipient.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(recipient.kind.rawValue.capitalized)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    if let trade = recipient.trade {
                        Text(trade).font(.caption2).foregroundColor(.secondary)
                    }
                    if !recipient.hasEmail {
                        Text("· no email").font(.caption2).foregroundColor(.red)
                    }
                }
            }
            Spacer()
            TextField("Amount", text: $amountText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
                .disabled(!isSelected)
                .opacity(isSelected ? 1 : 0.4)
        }
    }
}

private struct ResultsSummaryHeader: View {
    let results: [BulkLienWaiverService.RecipientResult]
    var body: some View {
        let ok = results.filter { if case .success = $0.outcome { return true } else { return false } }.count
        let skipped = results.filter { if case .skippedNoEmail = $0.outcome { return true } else { return false } }.count
        let failed = results.count - ok - skipped
        VStack(alignment: .leading, spacing: 8) {
            Text("Sent \(ok) of \(results.count)")
                .font(.title3.weight(.semibold))
            HStack(spacing: 14) {
                statBlock(label: "Sent", value: ok, color: .green, icon: "checkmark.circle.fill")
                statBlock(label: "Skipped", value: skipped, color: .orange, icon: "minus.circle.fill")
                statBlock(label: "Failed", value: failed, color: .red, icon: "xmark.circle.fill")
            }
        }
        .padding(.vertical, 4)
    }
    private func statBlock(label: String, value: Int, color: Color, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundColor(color)
            Text("\(value)").font(.subheadline.weight(.semibold))
            Text(label).font(.caption).foregroundColor(.secondary)
        }
    }
}

private struct BulkResultRow: View {
    let result: BulkLienWaiverService.RecipientResult
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.displayName).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
    private var icon: String {
        switch result.outcome {
        case .success:        return "checkmark.circle.fill"
        case .skippedNoEmail: return "minus.circle.fill"
        case .createFailed,
             .mintFailed,
             .emailFailed:    return "xmark.circle.fill"
        }
    }
    private var color: Color {
        switch result.outcome {
        case .success:        return .green
        case .skippedNoEmail: return .orange
        case .createFailed,
             .mintFailed,
             .emailFailed:    return .red
        }
    }
    private var detail: String {
        switch result.outcome {
        case .success(_, let url):    return "Email sent · \(url.absoluteString)"
        case .skippedNoEmail:         return "No email on file — skipped."
        case .createFailed(let m):    return "Couldn't create waiver: \(m)"
        case .mintFailed(let m):      return "Waiver created but link mint failed: \(m)"
        case .emailFailed(let m):     return "Waiver minted, email failed: \(m)"
        }
    }
}
