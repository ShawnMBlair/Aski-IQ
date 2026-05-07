// SubcontractorViews.swift
// Aski IQ – Subcontractor Management UI
// List → Detail → Sub-Contract detail, with compliance tracking.

import SwiftUI

// MARK: - Global List

struct SubcontractorListView: View {
    @EnvironmentObject var store: AppStore
    @State private var search = ""
    @State private var showCreate = false

    private var filtered: [Subcontractor] {
        let list = store.subcontractors.sorted { $0.companyName < $1.companyName }
        if search.isEmpty { return list }
        return list.filter {
            $0.companyName.localizedCaseInsensitiveContains(search) ||
            ($0.trade?.localizedCaseInsensitiveContains(search) == true) ||
            ($0.contactName?.localizedCaseInsensitiveContains(search) == true)
        }
    }

    var body: some View {
        SubcontractorListBody(items: filtered, showCreate: $showCreate)
            .navigationTitle("Subcontractors")
            .searchable(text: $search, prompt: "Search by name or trade")
            .refreshable { await store.refreshAll() }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if store.currentUserRole.canManageSubcontractors {
                        Button { showCreate = true } label: { Image(systemName: "plus") }
                    }
                }
            }
            .sheet(isPresented: $showCreate) { SubcontractorCreateEditView() }
    }
}

private struct SubcontractorListBody: View {
    let items: [Subcontractor]
    @Binding var showCreate: Bool
    @EnvironmentObject var store: AppStore

    var body: some View {
        List {
            SubcontractorListSummary()
            if items.isEmpty {
                SubcontractorEmptyRow()
            } else {
                ForEach(items) { sub in
                    NavigationLink(destination: SubcontractorDetailView(subcontractor: sub)) {
                        SubcontractorRow(sub: sub)
                    }
                }
            }
        }
    }
}

private struct SubcontractorListSummary: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        let active    = store.subcontractors.filter { $0.status == .active }
        let alerts    = store.subcontractorsWithComplianceAlerts
        let openSCs   = store.openSubContracts
        Section {
            HStack(spacing: 0) {
                SubSummaryCell(label: "Active",    value: "\(active.count)", color: .green)
                Divider().frame(height: 36)
                SubSummaryCell(label: "Compliance Alerts", value: "\(alerts.count)",
                               color: alerts.isEmpty ? .secondary : .red)
                Divider().frame(height: 36)
                SubSummaryCell(label: "Open Contracts", value: "\(openSCs.count)",
                               color: openSCs.isEmpty ? .secondary : .blue)
            }
        }
    }
}

private struct SubSummaryCell: View {
    let label: String; let value: String; let color: Color
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).foregroundColor(color)
            Text(label).font(.caption).foregroundColor(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

private struct SubcontractorEmptyRow: View {
    var body: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "building.2").font(.largeTitle).foregroundColor(.secondary)
                Text("No subcontractors yet.").font(.subheadline).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 24)
        }
    }
}

// MARK: - Row

struct SubcontractorRow: View {
    let sub: Subcontractor

    var body: some View {
        HStack(spacing: 12) {
            SubcontractorAvatar(sub: sub, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(sub.companyName).font(.subheadline).bold()
                    SubStatusBadge(status: sub.status)
                }
                if let trade = sub.trade {
                    Text(trade).font(.caption).foregroundColor(.secondary)
                }
                if let contact = sub.contactName {
                    Text(contact).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            if sub.complianceAlertCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red).font(.subheadline)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail View

struct SubcontractorDetailView: View {
    @EnvironmentObject var store: AppStore
    @State private var sub: Subcontractor
    @State private var showEdit = false
    @State private var showAddContract = false
    @State private var showDeleteConfirm = false

    @State private var showDeletionBlocked = false
    @State private var deletionBlockedReason = ""
    @Environment(\.dismiss) var dismiss

    init(subcontractor: Subcontractor) { _sub = State(initialValue: subcontractor) }

    private var contracts: [SubContract] {
        store.subContracts(bySubcontractor: sub.id).sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SubDetailHeaderCard(sub: sub)
                SubDetailComplianceCard(sub: sub)
                SubDetailContractsSection(sub: sub, contracts: contracts, showAddContract: $showAddContract)
                Spacer(minLength: 32)
            }
            .padding(.top)
        }
        .navigationTitle(sub.companyName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if store.currentUserRole.canManageSubcontractors {
                    Menu {
                        Button { showEdit = true } label: { Label("Edit", systemImage: "pencil") }
                        Button(role: .destructive) { showDeleteConfirm = true } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .sheet(isPresented: $showEdit, onDismiss: { refreshFromStore() }) {
            SubcontractorCreateEditView(existing: sub)
        }
        .sheet(isPresented: $showAddContract) {
            SubContractCreateEditView(subcontractorID: sub.id)
        }
        .confirmationDialog("Delete \(sub.companyName)?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                switch store.deleteSubcontractor(sub) {
                case .success:
                    dismiss()
                case .failure(let err):
                    deletionBlockedReason = err.errorDescription ?? "Cannot delete subcontractor."
                    showDeletionBlocked = true
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Cannot Delete Subcontractor", isPresented: $showDeletionBlocked) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionBlockedReason)
        }
        .onReceive(store.$subcontractors) { _ in refreshFromStore() }
    }

    private func refreshFromStore() {
        if let updated = store.subcontractors.first(where: { $0.id == sub.id }) { sub = updated }
    }
}

private struct SubDetailHeaderCard: View {
    let sub: Subcontractor
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                SubcontractorAvatar(sub: sub, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(sub.companyName).font(.title3).bold()
                        SubStatusBadge(status: sub.status)
                    }
                    if let trade = sub.trade { Text(trade).font(.subheadline).foregroundColor(.secondary) }
                }
            }
            Divider()
            SubContactInfoGrid(sub: sub)
            if let rating = sub.rating {
                Divider()
                HStack {
                    Text("Rating").font(.subheadline).foregroundColor(.secondary)
                    Spacer()
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { i in
                            Image(systemName: i <= rating ? "star.fill" : "star")
                                .foregroundColor(i <= rating ? .yellow : .secondary).font(.caption)
                        }
                    }
                }
            }
            if let notes = sub.notes, !notes.isEmpty {
                Divider()
                Text(notes).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16).padding(.horizontal)
    }
}

private struct SubContactInfoGrid: View {
    let sub: Subcontractor
    var body: some View {
        VStack(spacing: 6) {
            if let contact = sub.contactName { SubInfoRow(label: "Contact", value: contact, icon: "person") }
            if let email   = sub.email       { SubInfoRow(label: "Email",   value: email,   icon: "envelope") }
            if let phone   = sub.phone       { SubInfoRow(label: "Phone",   value: phone,   icon: "phone") }
            if let addr    = sub.address     { SubInfoRow(label: "Address", value: addr,    icon: "mappin") }
        }
    }
}

private struct SubInfoRow: View {
    let label: String; let value: String; let icon: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundColor(.secondary).font(.caption).frame(width: 16)
            Text(label).font(.caption).foregroundColor(.secondary).frame(width: 60, alignment: .leading)
            Text(value).font(.subheadline)
            Spacer()
        }
    }
}

private struct SubDetailComplianceCard: View {
    let sub: Subcontractor
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compliance").font(.headline).padding(.horizontal)
            VStack(spacing: 0) {
                SubComplianceRow(
                    label: "Insurance",
                    expiry: sub.insuranceExpiry,
                    isExpired: sub.isInsuranceExpired,
                    isWarningSoon: sub.isInsuranceExpiringSoon,
                    detail: sub.insurancePolicyNumber.map { "Policy: \($0)" }
                )
                Divider().padding(.leading)
                SubComplianceRow(
                    label: "WCB / Workers' Comp",
                    expiry: sub.wcbExpiry,
                    isExpired: sub.isWCBExpired,
                    isWarningSoon: false,
                    detail: sub.wcbAccount.map { "Account: \($0)" }
                )
                if sub.hasCOR {
                    Divider().padding(.leading)
                    SubComplianceRow(
                        label: "COR Certification",
                        expiry: sub.corExpiry,
                        isExpired: sub.corExpiry.map { Date() > $0 } ?? false,
                        isWarningSoon: false,
                        detail: nil
                    )
                }
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12).padding(.horizontal)
        }
    }
}

private struct SubComplianceRow: View {
    let label: String
    let expiry: Date?
    let isExpired: Bool
    let isWarningSoon: Bool
    let detail: String?

    private var statusColor: Color {
        if isExpired      { return .red }
        if isWarningSoon  { return .orange }
        return .green
    }

    private var statusIcon: String {
        if isExpired     { return "xmark.circle.fill" }
        if isWarningSoon { return "exclamationmark.circle.fill" }
        return "checkmark.circle.fill"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.subheadline)
                if let d = detail { Text(d).font(.caption).foregroundColor(.secondary) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Image(systemName: statusIcon).foregroundColor(statusColor)
                if let exp = expiry {
                    Text(exp.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundColor(isExpired ? .red : .secondary)
                } else {
                    Text("Not on file").font(.caption).foregroundColor(.red)
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 10)
    }
}

private struct SubDetailContractsSection: View {
    @EnvironmentObject var store: AppStore
    let sub: Subcontractor
    let contracts: [SubContract]
    @Binding var showAddContract: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Sub-Contracts", count: contracts.count)
                if store.currentUserRole.canManageSubcontractors {
                    Button { showAddContract = true } label: {
                        Image(systemName: "plus.circle").foregroundColor(.blue)
                    }
                    .padding(.trailing)
                }
            }
            if contracts.isEmpty {
                EmptyCard(message: "No contracts yet for this subcontractor.")
            } else {
                VStack(spacing: 0) {
                    ForEach(contracts) { sc in
                        NavigationLink(destination: SubContractDetailView(subContract: sc)) {
                            SubContractRow(sc: sc)
                        }
                        if sc.id != contracts.last?.id { Divider().padding(.leading) }
                    }
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12).padding(.horizontal)
            }
        }
    }
}

// MARK: - Sub-Contract Row

struct SubContractRow: View {
    @EnvironmentObject var store: AppStore
    let sc: SubContract

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SubContractStatusBadge(status: sc.status)
                Spacer()
                Text(sc.contractValue.currencyString).font(.subheadline).bold()
            }
            Text(sc.contractNumber).font(.caption2).foregroundColor(.secondary)
            if let proj = store.project(id: sc.projectID) {
                Text(proj.name).font(.subheadline)
            }
            if !sc.scope.isEmpty {
                Text(sc.scope).font(.caption).foregroundColor(.secondary).lineLimit(2)
            }
            if sc.status.isOpen {
                SubContractProgressBar(sc: sc)
            }
        }
        .padding(.horizontal).padding(.vertical, 10)
    }
}

private struct SubContractProgressBar: View {
    let sc: SubContract
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Invoiced: \(sc.invoicedToDate.currencyString)").font(.caption2).foregroundColor(.secondary)
                Spacer()
                Text("\(Int(sc.percentComplete * 100))%").font(.caption2).bold()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(.systemGray5)).frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.blue)
                        .frame(width: max(geo.size.width * CGFloat(sc.percentComplete), 3), height: 6)
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Sub-Contract Detail

struct SubContractDetailView: View {
    @EnvironmentObject var store: AppStore
    @State private var sc: SubContract
    @State private var showEdit          = false
    @State private var showShareSheet    = false
    @State private var shareItems: [Any] = []
    @State private var isGeneratingPDF   = false
    @Environment(\.dismiss) var dismiss

    init(subContract: SubContract) { _sc = State(initialValue: subContract) }

    private var sub: Subcontractor? { store.subcontractor(id: sc.subcontractorID) }
    private var project: Project? { store.project(id: sc.projectID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SubContractHeaderCard(sc: sc, sub: sub, project: project)
                SubContractFinancialCard(sc: sc)
                SubContractStatusActions(sc: $sc)
                // Phase-2 deferred audit fix: bridge to a full Contract
                // record. Hidden behind a card so the financial flow
                // stays clean for users who don't need the legal side.
                SubContractContractLinkCard(sc: $sc)
                Spacer(minLength: 32)
            }
            .padding(.top)
        }
        .navigationTitle(sc.contractNumber)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    if isGeneratingPDF {
                        ProgressView().tint(.blue)
                    } else {
                        Button { exportPDF() } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    if store.currentUserRole.canManageSubcontractors {
                        Button { showEdit = true } label: { Image(systemName: "pencil") }
                    }
                }
            }
        }
        .sheet(isPresented: $showEdit, onDismiss: {
            if let updated = store.subContracts.first(where: { $0.id == sc.id }) { sc = updated }
        }) {
            SubContractCreateEditView(existing: sc, subcontractorID: sc.subcontractorID)
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        .onReceive(store.$subContracts) { all in
            if let updated = all.first(where: { $0.id == sc.id }) { sc = updated }
        }
    }

    // MARK: PDF Export

    private func exportPDF() {
        isGeneratingPDF = true
        let capturedSC   = sc
        let subName      = sub?.companyName ?? "—"
        let projName     = project?.name
        let company      = AppSettings.shared.companyName.isEmpty
            ? "Aski IQ" : AppSettings.shared.companyName
        Task.detached(priority: .userInitiated) {
            let pdfData = SubContractPDFRenderer(
                subContract:       capturedSC,
                subcontractorName: subName,
                projectName:       projName,
                companyName:       company
            ).render()
            let safe = capturedSC.contractNumber
                .components(separatedBy: .whitespacesAndNewlines).joined(separator: "_")
            let url  = FileManager.default.temporaryDirectory
                .appendingPathComponent("SubContract_\(safe).pdf")
            try? pdfData.write(to: url)
            await MainActor.run {
                shareItems      = [url]
                isGeneratingPDF = false
                showShareSheet  = true
            }
        }
    }
}

private struct SubContractHeaderCard: View {
    let sc: SubContract
    let sub: Subcontractor?
    let project: Project?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SubContractStatusBadge(status: sc.status)
                Spacer()
                if let start = sc.startDate, let end = sc.endDate {
                    Text("\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            if let sub = sub {
                Label(sub.companyName, systemImage: "building.2").font(.subheadline).foregroundColor(.secondary)
            }
            if let proj = project {
                Label(proj.name, systemImage: "folder.fill").font(.subheadline).foregroundColor(.secondary)
            }
            if !sc.scope.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scope of Work").font(.caption).foregroundColor(.secondary)
                    Text(sc.scope).font(.subheadline)
                }
            }
            if let notes = sc.notes, !notes.isEmpty {
                Divider()
                Text(notes).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16).padding(.horizontal)
    }
}

private struct SubContractFinancialCard: View {
    let sc: SubContract
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Financials").font(.headline).padding(.horizontal)
            VStack(spacing: 0) {
                SubFinRow(label: "Contract Value",  value: sc.contractValue.currencyString, bold: true)
                Divider(); SubFinRow(label: "Invoiced to Date", value: sc.invoicedToDate.currencyString, bold: false)
                Divider(); SubFinRow(label: "Retention (\(NSDecimalNumber(decimal: sc.retentionPercent).intValue)%)", value: sc.retentionAmount.currencyString, bold: false)
                Divider(); SubFinRow(label: "Paid to Date",     value: sc.paidToDate.currencyString, bold: false)
                if sc.netPayable > 0 {
                    Divider()
                    SubFinRow(label: "Net Payable", value: sc.netPayable.currencyString, bold: true, color: .orange)
                }
                if sc.remainingValue > 0 {
                    Divider()
                    SubFinRow(label: "Remaining Value", value: sc.remainingValue.currencyString, bold: false, color: .blue)
                }
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Progress").font(.subheadline).foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(sc.percentComplete * 100))%").font(.subheadline).bold()
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4).fill(Color(.systemGray5)).frame(height: 10)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.blue)
                                .frame(width: max(geo.size.width * CGFloat(sc.percentComplete), 4), height: 10)
                        }
                    }
                    .frame(height: 10)
                }
                .padding(.horizontal).padding(.vertical, 10)
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12).padding(.horizontal)
        }
    }
}

private struct SubFinRow: View {
    let label: String; let value: String; let bold: Bool; var color: Color = .primary
    var body: some View {
        HStack {
            Text(label).font(.subheadline).foregroundColor(bold ? .primary : .secondary)
            Spacer()
            Text(value).font(.subheadline).bold(bold).foregroundColor(color)
        }
        .padding(.horizontal).padding(.vertical, 10)
    }
}

private struct SubContractStatusActions: View {
    @EnvironmentObject var store: AppStore
    @Binding var sc: SubContract

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Actions").font(.headline).padding(.horizontal)
            VStack(spacing: 8) {
                if sc.status == .draft {
                    SubActionButton(label: "Mark Executed", color: .blue, icon: "signature") {
                        var u = sc; u.status = .executed; u.executedDate = Date(); store.upsertSubContract(u)
                    }
                }
                if sc.status == .executed {
                    SubActionButton(label: "Mark In Progress", color: .green, icon: "play.fill") {
                        var u = sc; u.status = .inProgress; store.upsertSubContract(u)
                    }
                }
                if sc.status == .inProgress {
                    SubActionButton(label: "Mark Complete", color: .teal, icon: "checkmark.circle.fill") {
                        var u = sc; u.status = .complete; store.upsertSubContract(u)
                    }
                    SubActionButton(label: "Mark Disputed", color: .red, icon: "exclamationmark.triangle") {
                        var u = sc; u.status = .disputed; store.upsertSubContract(u)
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

private struct SubActionButton: View {
    let label: String; let color: Color; let icon: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.subheadline).bold()
                .frame(maxWidth: .infinity).padding()
                .background(color.opacity(0.12)).foregroundColor(color)
                .cornerRadius(12)
        }
    }
}

// MARK: - Create / Edit — Subcontractor

struct SubcontractorCreateEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    var existing: Subcontractor? = nil

    @State private var companyName = ""
    @State private var trade       = ""
    @State private var contactName = ""
    @State private var contactTitle = ""
    @State private var email       = ""
    @State private var phone       = ""
    @State private var address     = ""
    @State private var status: SubcontractorStatus = .active
    @State private var insPolicy   = ""
    @State private var insExpiry   = Date()
    @State private var hasInsExpiry = false
    @State private var insAmount   = ""
    @State private var wcbAccount  = ""
    @State private var wcbExpiry   = Date()
    @State private var hasWCBExpiry = false
    @State private var hasCOR      = false
    @State private var corExpiry   = Date()
    @State private var hasCorExpiry = false
    @State private var notes       = ""
    @State private var rating: Int = 0

    private var isEditing: Bool { existing != nil }

    var body: some View {
        NavigationStack {
            SubcontractorCreateForm(
                companyName: $companyName, trade: $trade,
                contactName: $contactName, contactTitle: $contactTitle,
                email: $email, phone: $phone, address: $address,
                status: $status,
                insPolicy: $insPolicy, insExpiry: $insExpiry, hasInsExpiry: $hasInsExpiry, insAmount: $insAmount,
                wcbAccount: $wcbAccount, wcbExpiry: $wcbExpiry, hasWCBExpiry: $hasWCBExpiry,
                hasCOR: $hasCOR, corExpiry: $corExpiry, hasCorExpiry: $hasCorExpiry,
                notes: $notes, rating: $rating
            )
            .navigationTitle(isEditing ? "Edit Subcontractor" : "New Subcontractor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }.bold()
                        .disabled(companyName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear { populate() }
    }

    private func populate() {
        guard let s = existing else { return }
        companyName   = s.companyName
        trade         = s.trade ?? ""
        contactName   = s.contactName ?? ""
        contactTitle  = s.contactTitle ?? ""
        email         = s.email ?? ""
        phone         = s.phone ?? ""
        address       = s.address ?? ""
        status        = s.status
        insPolicy     = s.insurancePolicyNumber ?? ""
        insAmount     = s.insuranceAmount.map { "\($0)" } ?? ""
        if let d = s.insuranceExpiry { insExpiry = d; hasInsExpiry = true }
        wcbAccount    = s.wcbAccount ?? ""
        if let d = s.wcbExpiry { wcbExpiry = d; hasWCBExpiry = true }
        hasCOR        = s.hasCOR
        if let d = s.corExpiry { corExpiry = d; hasCorExpiry = true }
        notes         = s.notes ?? ""
        rating        = s.rating ?? 0
    }

    private func save() {
        var sub = existing ?? Subcontractor(companyName: companyName)
        sub.companyName         = companyName.trimmingCharacters(in: .whitespaces)
        sub.trade               = trade.isEmpty ? nil : trade
        sub.contactName         = contactName.isEmpty ? nil : contactName
        sub.contactTitle        = contactTitle.isEmpty ? nil : contactTitle
        sub.email               = email.isEmpty ? nil : email
        sub.phone               = phone.isEmpty ? nil : phone
        sub.address             = address.isEmpty ? nil : address
        sub.status              = status
        sub.insurancePolicyNumber = insPolicy.isEmpty ? nil : insPolicy
        sub.insuranceExpiry     = hasInsExpiry ? insExpiry : nil
        sub.insuranceAmount     = insAmount.isEmpty ? nil : Decimal(string: insAmount)
        sub.wcbAccount          = wcbAccount.isEmpty ? nil : wcbAccount
        sub.wcbExpiry           = hasWCBExpiry ? wcbExpiry : nil
        sub.hasCOR              = hasCOR
        sub.corExpiry           = (hasCOR && hasCorExpiry) ? corExpiry : nil
        sub.notes               = notes.isEmpty ? nil : notes
        sub.rating              = rating == 0 ? nil : rating
        store.upsertSubcontractor(sub)
        dismiss()
    }
}

private struct SubcontractorCreateForm: View {
    @Binding var companyName: String; @Binding var trade: String
    @Binding var contactName: String; @Binding var contactTitle: String
    @Binding var email: String; @Binding var phone: String; @Binding var address: String
    @Binding var status: SubcontractorStatus
    @Binding var insPolicy: String; @Binding var insExpiry: Date; @Binding var hasInsExpiry: Bool; @Binding var insAmount: String
    @Binding var wcbAccount: String; @Binding var wcbExpiry: Date; @Binding var hasWCBExpiry: Bool
    @Binding var hasCOR: Bool; @Binding var corExpiry: Date; @Binding var hasCorExpiry: Bool
    @Binding var notes: String; @Binding var rating: Int

    var body: some View {
        Form {
            SubCreateIdentitySection(companyName: $companyName, trade: $trade, status: $status)
            SubCreateContactSection(contactName: $contactName, contactTitle: $contactTitle, email: $email, phone: $phone, address: $address)
            SubCreateInsuranceSection(insPolicy: $insPolicy, insExpiry: $insExpiry, hasInsExpiry: $hasInsExpiry, insAmount: $insAmount)
            SubCreateWCBSection(wcbAccount: $wcbAccount, wcbExpiry: $wcbExpiry, hasWCBExpiry: $hasWCBExpiry)
            SubCreateCORSection(hasCOR: $hasCOR, corExpiry: $corExpiry, hasCorExpiry: $hasCorExpiry)
            SubCreateNotesSection(notes: $notes, rating: $rating)
        }
    }
}

private struct SubCreateIdentitySection: View {
    @Binding var companyName: String; @Binding var trade: String; @Binding var status: SubcontractorStatus
    var body: some View {
        Section("Company") {
            TextField("Company Name", text: $companyName)
            TextField("Trade / Specialty", text: $trade)
            Picker("Status", selection: $status) {
                ForEach(SubcontractorStatus.allCases, id: \.self) { s in Text(s.displayName).tag(s) }
            }
        }
    }
}

private struct SubCreateContactSection: View {
    @Binding var contactName: String; @Binding var contactTitle: String
    @Binding var email: String; @Binding var phone: String; @Binding var address: String
    var body: some View {
        Section("Primary Contact") {
            TextField("Contact Name", text: $contactName)
            TextField("Title / Role", text: $contactTitle)
            TextField("Email", text: $email).keyboardType(.emailAddress).autocapitalization(.none)
            TextField("Phone", text: $phone).keyboardType(.phonePad)
            TextField("Address", text: $address)
        }
    }
}

private struct SubCreateInsuranceSection: View {
    @Binding var insPolicy: String; @Binding var insExpiry: Date; @Binding var hasInsExpiry: Bool; @Binding var insAmount: String
    var body: some View {
        Section("Insurance") {
            TextField("Policy Number", text: $insPolicy)
            Toggle("Set Expiry Date", isOn: $hasInsExpiry)
            if hasInsExpiry { DatePicker("Expiry", selection: $insExpiry, displayedComponents: .date) }
            HStack {
                Text("Coverage Limit ($)"); Spacer()
                TextField("0", text: $insAmount).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 130)
            }
        }
    }
}

private struct SubCreateWCBSection: View {
    @Binding var wcbAccount: String; @Binding var wcbExpiry: Date; @Binding var hasWCBExpiry: Bool
    var body: some View {
        Section("WCB / Workers' Comp") {
            TextField("Account Number", text: $wcbAccount)
            Toggle("Set Clearance Expiry", isOn: $hasWCBExpiry)
            if hasWCBExpiry { DatePicker("Expiry", selection: $wcbExpiry, displayedComponents: .date) }
        }
    }
}

private struct SubCreateCORSection: View {
    @Binding var hasCOR: Bool; @Binding var corExpiry: Date; @Binding var hasCorExpiry: Bool
    var body: some View {
        Section("Safety Certification") {
            Toggle("Holds COR Certificate", isOn: $hasCOR)
            if hasCOR {
                Toggle("Set COR Expiry", isOn: $hasCorExpiry)
                if hasCorExpiry { DatePicker("COR Expiry", selection: $corExpiry, displayedComponents: .date) }
            }
        }
    }
}

private struct SubCreateNotesSection: View {
    @Binding var notes: String; @Binding var rating: Int
    var body: some View {
        Section("Notes & Rating") {
            TextField("Internal notes…", text: $notes, axis: .vertical).lineLimit(3...8)
            HStack {
                Text("Rating")
                Spacer()
                HStack(spacing: 4) {
                    ForEach(1...5, id: \.self) { i in
                        Button { rating = (rating == i) ? 0 : i } label: {
                            Image(systemName: i <= rating ? "star.fill" : "star")
                                .foregroundColor(i <= rating ? .yellow : .secondary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Create / Edit — Sub-Contract

struct SubContractCreateEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    var existing: SubContract? = nil
    let subcontractorID: UUID

    @State private var projectID: UUID? = nil
    @State private var scope        = ""
    @State private var contractValue = ""
    @State private var retentionPct  = "10"
    @State private var invoiced      = ""
    @State private var paid          = ""
    @State private var paymentTerms  = ""
    @State private var hasStartDate  = false
    @State private var startDate     = Date()
    @State private var hasEndDate    = false
    @State private var endDate       = Calendar.current.date(byAdding: .month, value: 3, to: Date()) ?? Date()
    @State private var notes         = ""

    var body: some View {
        NavigationStack {
            Form {
                SubContractProjectSection(projectID: $projectID)
                SubContractScopeSection(scope: $scope, paymentTerms: $paymentTerms)
                SubContractFinancialSection(contractValue: $contractValue, retentionPct: $retentionPct, invoiced: $invoiced, paid: $paid)
                SubContractDatesSection(hasStartDate: $hasStartDate, startDate: $startDate, hasEndDate: $hasEndDate, endDate: $endDate)
                Section("Notes") { TextField("Notes…", text: $notes, axis: .vertical).lineLimit(2...6) }
            }
            .navigationTitle(existing == nil ? "New Sub-Contract" : "Edit Sub-Contract")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }.bold().disabled(projectID == nil)
                }
            }
        }
        .onAppear { populate() }
    }

    private func populate() {
        guard let sc = existing else { return }
        projectID     = sc.projectID
        scope         = sc.scope
        contractValue = "\(sc.contractValue)"
        retentionPct  = "\(sc.retentionPercent)"
        invoiced      = "\(sc.invoicedToDate)"
        paid          = "\(sc.paidToDate)"
        paymentTerms  = sc.paymentTerms ?? ""
        notes         = sc.notes ?? ""
        if let d = sc.startDate { startDate = d; hasStartDate = true }
        if let d = sc.endDate   { endDate   = d; hasEndDate   = true }
    }

    private func save() {
        guard let projID = projectID else { return }
        var sc = existing ?? SubContract(
            contractNumber: store.nextSubContractNumber(),
            subcontractorID: subcontractorID,
            projectID: projID
        )
        sc.projectID       = projID
        sc.scope           = scope
        sc.contractValue   = Decimal(string: contractValue) ?? 0
        sc.retentionPercent = Decimal(string: retentionPct) ?? 10
        sc.invoicedToDate  = Decimal(string: invoiced) ?? 0
        sc.paidToDate      = Decimal(string: paid) ?? 0
        sc.paymentTerms    = paymentTerms.isEmpty ? nil : paymentTerms
        sc.startDate       = hasStartDate ? startDate : nil
        sc.endDate         = hasEndDate   ? endDate   : nil
        sc.notes           = notes.isEmpty ? nil : notes
        store.upsertSubContract(sc)
        dismiss()
    }
}

private struct SubContractProjectSection: View {
    @EnvironmentObject var store: AppStore
    @Binding var projectID: UUID?
    var body: some View {
        Section("Project") {
            Picker("Project", selection: $projectID) {
                Text("Select Project").tag(UUID?.none)
                ForEach(store.projects.filter { $0.status == .active || $0.status == .awarded }) { p in
                    Text(p.name).tag(Optional(p.id))
                }
            }
        }
    }
}

private struct SubContractScopeSection: View {
    @Binding var scope: String; @Binding var paymentTerms: String
    var body: some View {
        Section("Scope") {
            TextField("Scope of work…", text: $scope, axis: .vertical).lineLimit(3...8)
            TextField("Payment terms (e.g. Net 30)", text: $paymentTerms)
        }
    }
}

private struct SubContractFinancialSection: View {
    @Binding var contractValue: String; @Binding var retentionPct: String
    @Binding var invoiced: String; @Binding var paid: String
    var body: some View {
        Section("Financial") {
            HStack { Text("Contract Value ($)"); Spacer(); TextField("0.00", text: $contractValue).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 130) }
            HStack { Text("Retention (%)");      Spacer(); TextField("10",   text: $retentionPct).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 60)  }
            HStack { Text("Invoiced to Date ($)"); Spacer(); TextField("0.00", text: $invoiced).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 130) }
            HStack { Text("Paid to Date ($)");   Spacer(); TextField("0.00", text: $paid).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 130) }
        }
    }
}

private struct SubContractDatesSection: View {
    @Binding var hasStartDate: Bool; @Binding var startDate: Date
    @Binding var hasEndDate: Bool;   @Binding var endDate: Date
    var body: some View {
        Section("Schedule") {
            Toggle("Set Start Date", isOn: $hasStartDate)
            if hasStartDate { DatePicker("Start", selection: $startDate, displayedComponents: .date) }
            Toggle("Set End Date", isOn: $hasEndDate)
            if hasEndDate { DatePicker("End", selection: $endDate, displayedComponents: .date) }
        }
    }
}

// MARK: - Avatar / Badges

struct SubcontractorAvatar: View {
    let sub: Subcontractor; let size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25)
                .fill(Color.indigo.opacity(0.12))
                .frame(width: size, height: size)
            Text(sub.initials).font(.system(size: size * 0.35, weight: .bold)).foregroundColor(.indigo)
        }
    }
}

struct SubStatusBadge: View {
    let status: SubcontractorStatus
    private var color: Color {
        switch status {
        case .active:       return .green
        case .inactive:     return .gray
        case .probationary: return .orange
        case .suspended:    return .red
        case .blacklisted:  return .red
        }
    }
    var body: some View {
        if status != .active {
            Label(status.displayName, systemImage: status.icon)
                .font(.caption2).bold()
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(color.opacity(0.12)).foregroundColor(color).cornerRadius(6)
        }
    }
}

struct SubContractStatusBadge: View {
    let status: SubContractStatus
    private var color: Color {
        switch status {
        case .draft:      return .gray
        case .executed:   return .blue
        case .inProgress: return .green
        case .complete:   return .teal
        case .disputed:   return .red
        case .terminated: return .gray
        }
    }
    var body: some View {
        Text(status.displayName)
            .font(.caption2).bold()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15)).foregroundColor(color).cornerRadius(6)
    }
}

// MARK: - Project Sub-Contracts Section (used in ProjectDetailView)

struct ProjectSubcontractorsSection: View {
    @EnvironmentObject var store: AppStore
    let project: Project

    private var contracts: [SubContract] { store.subContracts(for: project.id) }

    var body: some View {
        Group {
            Divider().padding(.horizontal)
            HStack {
                SectionHeader(title: "Sub-Contracts", count: contracts.count)
                if !contracts.isEmpty {
                    NavigationLink(
                        "See All",
                        destination: ProjectSubContractListView(project: project)
                    )
                    .font(.subheadline).padding(.trailing)
                }
            }
            if contracts.isEmpty {
                EmptyCard(message: "No sub-contracts on this project.")
            } else {
                VStack(spacing: 0) {
                    ProjectSubContractStats(contracts: contracts)
                    Divider()
                    ForEach(contracts.prefix(3)) { sc in
                        NavigationLink(destination: SubContractDetailView(subContract: sc)) {
                            SubContractRow(sc: sc).padding(.vertical, -2)
                        }
                        if sc.id != contracts.prefix(3).last?.id { Divider().padding(.leading) }
                    }
                    if contracts.count > 3 {
                        Divider()
                        NavigationLink(destination: ProjectSubContractListView(project: project)) {
                            Text("See all \(contracts.count) sub-contracts")
                                .font(.subheadline).foregroundColor(.blue).frame(maxWidth: .infinity).padding()
                        }
                    }
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12).padding(.horizontal)
            }
        }
    }
}

private struct ProjectSubContractStats: View {
    let contracts: [SubContract]
    var body: some View {
        let totalValue = contracts.reduce(Decimal(0)) { $0 + $1.contractValue }
        let totalPaid  = contracts.reduce(Decimal(0)) { $0 + $1.paidToDate }
        let open       = contracts.filter { $0.status.isOpen }
        HStack(spacing: 0) {
            SubSummaryCell(label: "Open",      value: "\(open.count)",          color: open.isEmpty ? .secondary : .blue)
            Divider().frame(height: 36)
            SubSummaryCell(label: "Total Value", value: totalValue.currencyString, color: .primary)
            Divider().frame(height: 36)
            SubSummaryCell(label: "Paid",      value: totalPaid.currencyString,  color: .green)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Project Sub-Contract List

struct ProjectSubContractListView: View {
    @EnvironmentObject var store: AppStore
    let project: Project
    @State private var showAdd = false

    private var contracts: [SubContract] {
        store.subContracts(for: project.id).sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        List {
            if contracts.isEmpty {
                Text("No sub-contracts on this project.")
                    .font(.subheadline).foregroundColor(.secondary)
            } else {
                ForEach(contracts) { sc in
                    NavigationLink(destination: SubContractDetailView(subContract: sc)) {
                        SubContractRow(sc: sc)
                    }
                }
            }
        }
        .navigationTitle("Sub-Contracts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if store.currentUserRole.canManageSubcontractors {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            SubContractCreateEditView(subcontractorID: UUID()) // placeholder — user picks project
        }
    }
}

// MARK: - UserRole Extension

private extension UserRole {
    var canManageSubcontractors: Bool {
        [.projectManager, .officeAdmin, .manager, .executive, .owner].contains(self)
    }
}

// MARK: - SubContract → full Contract bridge card
//
// Phase-2 deferred audit fix. SubContract is the lightweight money
// tracker (invoiced / paid / retention) — it doesn't carry clauses,
// milestones, compliance docs, or e-sign workflow. When a sub-contract
// needs the full document side (executed agreement, attached
// insurance certs, lien-waiver tracking), an admin promotes it. The
// SubContract stays alive as the active billing record; the new
// Contract carries the legal framework. They link both ways via
// `linkedContractID` (and a marker line on Contract.notes).
//
// HIDDEN STATES
//   * No link & non-admin → card hidden
//   * No link & admin     → "Promote to Contract" button
//   * Linked              → "View Contract" navigation row
//   * Linked but contract was deleted → repair button (clears stale ID)

private struct SubContractContractLinkCard: View {
    @Binding var sc: SubContract
    @EnvironmentObject var store: AppStore
    @State private var showConfirm = false
    @State private var navigateContractID: UUID?

    private var linkedContract: Contract? {
        guard let id = sc.linkedContractID else { return nil }
        return store.contracts.first(where: { $0.id == id && !$0.isDeleted })
    }

    private var isAdmin: Bool {
        store.currentUserRole.isAdmin || store.currentUserRole == .manager || store.currentUserRole == .officeAdmin
    }

    var body: some View {
        // Hidden when there's nothing to do: no link AND user can't
        // create one. Keeps the detail view clean for ops/PM users.
        if !isAdmin && linkedContract == nil { EmptyView() }
        else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Legal Document")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                if let c = linkedContract {
                    NavigationLink {
                        ContractDetailView(contractID: c.id)
                    } label: {
                        HStack {
                            Image(systemName: "doc.text.fill").foregroundColor(.purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.contractNumber ?? "Contract")
                                    .font(.subheadline.weight(.semibold))
                                Text(c.title)
                                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        .padding(12)
                        .background(Color.purple.opacity(0.08))
                        .cornerRadius(10)
                    }
                } else if sc.linkedContractID != nil {
                    // Stale link — the linked Contract was soft-deleted.
                    Button(role: .destructive) {
                        sc.linkedContractID = nil
                        sc.syncStatus       = .pending
                        store.upsertSubContract(sc)
                    } label: {
                        Label("Linked contract is missing — clear stale link",
                              systemImage: "exclamationmark.triangle.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.orange.opacity(0.10))
                            .foregroundColor(.orange)
                            .cornerRadius(10)
                    }
                } else if isAdmin {
                    Button {
                        showConfirm = true
                    } label: {
                        HStack {
                            Image(systemName: "doc.badge.plus").foregroundColor(.purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Promote to full Contract")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.purple)
                                Text("Adds a legal document side: clauses, milestones, compliance docs, e-sign workflow.")
                                    .font(.caption).foregroundColor(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right.circle.fill")
                                .foregroundColor(.purple)
                        }
                        .padding(12)
                        .background(Color.purple.opacity(0.08))
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .alert("Promote to full Contract?",
                   isPresented: $showConfirm) {
                Button("Promote") {
                    if let c = store.promoteSubContractToContract(sc) {
                        // Refresh local copy so the card flips to
                        // the "View Contract" state immediately.
                        if let updated = store.subContracts.first(where: { $0.id == sc.id }) {
                            sc = updated
                        }
                        navigateContractID = c.id
                        ToastService.shared.success("Contract \(c.contractNumber ?? "") created.")
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This SubContract stays as your billing tracker. A new Contract record will carry the legal framework — clauses, milestones, compliance docs, and e-signature workflow. Both records will link back to each other.")
            }
        }
    }
}
