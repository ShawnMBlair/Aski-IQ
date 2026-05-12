// CertificateViews.swift
// BV APP – Worker Certification & Compliance UI

import SwiftUI
import PhotosUI

// MARK: - Certificate List View

struct CertificateListView: View {
    @EnvironmentObject var store: AppStore
    @State private var searchText       = ""
    @State private var filterStatus:    CertificateStatus? = nil
    @State private var filterType:      CertificationType? = nil
    @State private var showCreate       = false
    @StateObject private var pagination = PaginationState(pageSize: 25)

    private var filtered: [Certificate] {
        store.certificates
            .filter { filterStatus == nil || $0.status == filterStatus }
            .filter { filterType   == nil || $0.type   == filterType   }
            .filter {
                searchText.isEmpty ||
                $0.displayName.localizedCaseInsensitiveContains(searchText) ||
                employeeName(for: $0).localizedCaseInsensitiveContains(searchText) ||
                ($0.certNumber ?? "").localizedCaseInsensitiveContains(searchText) ||
                ($0.issuingBody ?? "").localizedCaseInsensitiveContains(searchText)
            }
            .sorted {
                let d0 = $0.expiryDate ?? .distantFuture
                let d1 = $1.expiryDate ?? .distantFuture
                return d0 < d1
            }
    }

    private var visible: [Certificate] {
        Array(filtered.prefix(pagination.displayLimit))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // Filter bar
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(label: "All",
                                   isSelected: filterStatus == nil && filterType == nil) {
                            filterStatus = nil; filterType = nil
                        }
                        FilterChip(label: "🔴 Expired",
                                   isSelected: filterStatus == .expired) {
                            filterStatus = filterStatus == .expired ? nil : .expired
                        }
                        FilterChip(label: "🟠 Expiring Soon",
                                   isSelected: filterStatus == .expiringSoon) {
                            filterStatus = filterStatus == .expiringSoon ? nil : .expiringSoon
                        }
                        FilterChip(label: "✅ Valid",
                                   isSelected: filterStatus == .valid) {
                            filterStatus = filterStatus == .valid ? nil : .valid
                        }
                        Divider().frame(height: 20)
                        ForEach(CertificationType.allCases, id: \.self) { t in
                            FilterChip(label: t.displayName, isSelected: filterType == t) {
                                filterType = filterType == t ? nil : t
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }
                Divider()

                // Compliance summary strip
                let alerts = store.complianceAlerts.count
                if alerts > 0 {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        let expired    = store.expiredCertificates.count
                        let expiringSoon = store.expiringCertificates.count
                        Text("\(expired) expired · \(expiringSoon) expiring soon")
                            .font(.subheadline)
                            .foregroundColor(.primary)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.08))
                    Divider()
                }

                if filtered.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 52)).foregroundColor(.green)
                        Text("No certifications found.").font(.headline)
                        Text("Add worker certs to track expiry dates.")
                            .font(.subheadline).foregroundColor(.secondary)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(visible) { cert in
                            NavigationLink {
                                CertificateDetailView(certificate: cert)
                            } label: {
                                CertificateRow(certificate: cert)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.deleteCertificate(cert)
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                        LoadMoreFooter(
                            showing: visible.count,
                            total:   filtered.count,
                            onLoad:  { pagination.loadMore() }
                        )
                    }
                    .listStyle(.plain)
                    .onChange(of: searchText)    { _ in pagination.reset() }
                    .onChange(of: filterStatus)  { _ in pagination.reset() }
                    .onChange(of: filterType)    { _ in pagination.reset() }
                }
            }
            .searchable(text: $searchText, prompt: "Search name, number or issuer")
            .navigationTitle("Certifications")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showCreate = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showCreate) {
                CertificateCreateEditView()
            }
        }
    }

    private func employeeName(for cert: Certificate) -> String {
        store.employees.first { $0.id == cert.employeeID }?.fullName ?? ""
    }
}

// MARK: - Certificate Row

struct CertificateRow: View {
    let certificate: Certificate
    @EnvironmentObject var store: AppStore

    private var employeeName: String {
        store.employees.first { $0.id == certificate.employeeID }?.fullName ?? "Unknown"
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(certificate.type.color.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: certificate.type.icon)
                    .foregroundColor(certificate.type.color)
                    .font(.system(size: 18))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(certificate.displayName)
                        .font(.subheadline).bold().lineLimit(1)
                    CertStatusBadge(status: certificate.status)
                }
                Text(employeeName)
                    .font(.caption).foregroundColor(.secondary)
                if let expiry = certificate.expiryDate {
                    let days = certificate.daysUntilExpiry ?? 0
                    let label = days < 0
                        ? "Expired \(abs(days))d ago"
                        : "Expires \(expiry.shortDate)"
                    Text(label)
                        .font(.caption2)
                        .foregroundColor(certificate.status == .expired ? .red :
                                         certificate.status == .expiringSoon ? .orange : .secondary)
                }
            }

            Spacer()

            if let num = certificate.certNumber {
                Text(num)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Certificate Detail View

struct CertificateDetailView: View {
    let certificate: Certificate
    @EnvironmentObject var store: AppStore
    @State private var showEdit = false

    private var employee: Employee? {
        store.employees.first { $0.id == certificate.employeeID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Header card
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(certificate.displayName)
                                .font(.title3).bold()
                            CertStatusBadge(status: certificate.status)
                        }
                        Spacer()
                        ZStack {
                            Circle()
                                .fill(certificate.type.color.opacity(0.15))
                                .frame(width: 56, height: 56)
                            Image(systemName: certificate.type.icon)
                                .font(.title2)
                                .foregroundColor(certificate.type.color)
                        }
                    }
                    Divider()

                    // Meta grid
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                        if let emp = employee {
                            GridRow {
                                metaCell(label: "Employee",   value: emp.fullName)
                                metaCell(label: "Role",       value: emp.role.rawValue.capitalized)
                            }
                        }
                        GridRow {
                            metaCell(label: "Type", value: certificate.type.displayName)
                            if let num = certificate.certNumber {
                                metaCell(label: "Certificate #", value: num)
                            }
                        }
                        if let issuer = certificate.issuingBody {
                            GridRow {
                                metaCell(label: "Issued By", value: issuer)
                                if let issued = certificate.issuedDate {
                                    metaCell(label: "Issue Date",
                                             value: issued.formatted(date: .abbreviated, time: .omitted))
                                }
                            }
                        }
                        GridRow {
                            if let expiry = certificate.expiryDate {
                                let days = certificate.daysUntilExpiry ?? 0
                                metaCell(label: "Expiry Date",
                                         value: expiry.formatted(date: .abbreviated, time: .omitted))
                                metaCell(label: days < 0 ? "Overdue By" : "Days Remaining",
                                         value: "\(abs(days))d",
                                         valueColor: certificate.status == .expired ? .red :
                                                     certificate.status == .expiringSoon ? .orange : .green)
                            } else {
                                metaCell(label: "Expiry", value: "No expiry date")
                            }
                        }
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(16)
                .padding(.horizontal)

                // Expiry alert banner
                if certificate.status == .expired || certificate.status == .expiringSoon {
                    expiryBanner
                        .padding(.horizontal)
                }

                // Notes
                if let notes = certificate.notes, !notes.isEmpty {
                    SectionHeader(title: "Notes")
                    Text(notes)
                        .font(.subheadline)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)
                }

                // Document preview
                if let data = certificate.documentData, let img = UIImage(data: data) {
                    SectionHeader(title: "Document")
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .cornerRadius(12)
                        .padding(.horizontal)
                }

                Spacer(minLength: 40)
            }
            .padding(.top)
        }
        .navigationTitle(certificate.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Edit") { showEdit = true }
            }
        }
        .sheet(isPresented: $showEdit) {
            CertificateCreateEditView(existing: certificate)
        }
    }

    private func metaCell(label: String, value: String, valueColor: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundColor(.secondary).textCase(.uppercase)
            Text(value).font(.subheadline).foregroundColor(valueColor)
        }
    }

    private var expiryBanner: some View {
        let isExpired = certificate.status == .expired
        let days = abs(certificate.daysUntilExpiry ?? 0)
        let msg = isExpired
            ? "This certification expired \(days) day\(days == 1 ? "" : "s") ago. Renewal required."
            : "This certification expires in \(days) day\(days == 1 ? "" : "s"). Schedule renewal now."
        return HStack(spacing: 12) {
            Image(systemName: isExpired ? "xmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundColor(isExpired ? .red : .orange)
            Text(msg)
                .font(.subheadline)
                .foregroundColor(.primary)
        }
        .padding(14)
        .background((isExpired ? Color.red : Color.orange).opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke((isExpired ? Color.red : Color.orange).opacity(0.3), lineWidth: 1))
        .cornerRadius(12)
    }
}

// MARK: - Certificate Create / Edit View

struct CertificateCreateEditView: View {
    var existing: Certificate? = nil
    var prelinkedEmployeeID: UUID? = nil

    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    @State private var selectedEmployeeID: UUID? = nil
    @State private var certType:    CertificationType = .whmis
    @State private var customName   = ""
    @State private var certNumber   = ""
    @State private var issuingBody  = ""
    @State private var issuedDate   = Date()
    @State private var hasIssuedDate = false
    @State private var hasExpiry    = true
    @State private var expiryDate   = Date()
    @State private var notes        = ""
    @State private var photoItem:   PhotosPickerItem? = nil
    /// FIX (debug audit): live camera for certificate scans.
    @State private var showCamera = false
    @State private var capturedPhoto: UIImage? = nil
    @State private var documentData: Data?           = nil

    @State private var showValidation = false
    @State private var validationMsg  = ""

    private var isEditing: Bool { existing != nil }

    var body: some View {
        NavigationStack {
            Form {

                // MARK: Employee
                Section("Employee *") {
                    if store.employees.isEmpty {
                        Text("No employees on file.").foregroundColor(.secondary)
                    } else {
                        Picker("Employee", selection: $selectedEmployeeID) {
                            Text("Select employee").tag(UUID?.none)
                            ForEach(store.employees.filter { $0.isActive }.sorted { $0.lastName < $1.lastName }) { emp in
                                Text(emp.fullName).tag(Optional(emp.id))
                            }
                        }
                    }
                }

                // MARK: Certification
                Section("Certification *") {
                    Picker("Type", selection: $certType) {
                        ForEach(CertificationType.allCases, id: \.self) { t in
                            Label(t.displayName, systemImage: t.icon).tag(t)
                        }
                    }
                    if certType == .other {
                        TextField("Certificate name", text: $customName)
                    }
                    TextField("Certificate / Ticket #", text: $certNumber)
                    TextField("Issuing authority / training provider", text: $issuingBody)
                }

                // MARK: Dates
                Section("Dates") {
                    Toggle("Has issue date", isOn: $hasIssuedDate)
                    if hasIssuedDate {
                        DatePicker("Issued", selection: $issuedDate, displayedComponents: .date)
                    }
                    Toggle("Has expiry date", isOn: $hasExpiry)
                    if hasExpiry {
                        DatePicker("Expires", selection: $expiryDate, displayedComponents: .date)
                        if let months = certType.defaultValidityMonths, !isEditing {
                            Button {
                                expiryDate = Calendar.current.date(
                                    byAdding: .month, value: months, to: hasIssuedDate ? issuedDate : Date()
                                ) ?? expiryDate
                            } label: {
                                Text("Set to standard \(months)-month validity")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // MARK: Notes
                Section("Notes") {
                    TextEditor(text: $notes).frame(minHeight: 60)
                }

                // MARK: Document
                Section("Certificate Document") {
                    // FIX (debug audit): camera + library, side-by-side.
                    HStack(spacing: 10) {
                        if CameraPicker.isAvailable {
                            Button {
                                showCamera = true
                            } label: {
                                Label("Take Photo", systemImage: "camera.fill")
                                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                            }
                        }
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label("From Library",
                                  systemImage: "photo.on.rectangle")
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(Color(.secondarySystemBackground))
                                .foregroundColor(.primary)
                                .cornerRadius(8)
                        }
                    }
                    .onChange(of: photoItem) { item in
                        Task {
                            documentData = try? await item?.loadTransferable(type: Data.self)
                        }
                    }
                    if let data = documentData, let img = UIImage(data: data) {
                        Image(uiImage: img)
                            .resizable().scaledToFit()
                            .frame(maxHeight: 160)
                            .cornerRadius(8)
                        Button(role: .destructive) { documentData = nil; photoItem = nil } label: {
                            Label("Remove Document", systemImage: "trash")
                                .font(.caption)
                        }
                    }
                }

                // MARK: Delete
                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            if let e = existing { store.deleteCertificate(e); dismiss() }
                        } label: {
                            Label("Delete Certification", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Certification" : "Add Certification")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }.bold()
                }
            }
            .alert("Missing Info", isPresented: $showValidation) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationMsg)
            }
            .onAppear { populate() }
            // FIX (debug audit): live camera sheet for cert scans.
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker(image: $capturedPhoto)
                    .ignoresSafeArea()
            }
            .onChange(of: capturedPhoto) { img in
                guard let img = img,
                      let data = img.jpegData(compressionQuality: 0.9) else { return }
                documentData = data
                capturedPhoto = nil
            }
        }
    }

    private func populate() {
        if existing == nil, let pid = prelinkedEmployeeID {
            selectedEmployeeID = pid
        }
        guard let e = existing else { return }
        selectedEmployeeID = e.employeeID
        certType           = e.type
        customName         = e.customName ?? ""
        certNumber         = e.certNumber ?? ""
        issuingBody        = e.issuingBody ?? ""
        hasIssuedDate      = e.issuedDate != nil
        issuedDate         = e.issuedDate ?? Date()
        hasExpiry          = e.expiryDate != nil
        expiryDate         = e.expiryDate ?? Date()
        notes              = e.notes ?? ""
        documentData       = e.documentData
    }

    private func save() {
        guard let empID = selectedEmployeeID else {
            validationMsg = "Please select an employee."; showValidation = true; return
        }
        if certType == .other && customName.trimmingCharacters(in: .whitespaces).isEmpty {
            validationMsg = "Please enter a name for this certification."; showValidation = true; return
        }

        var cert            = existing ?? Certificate(employeeID: empID)
        cert.employeeID     = empID
        cert.type           = certType
        cert.customName     = certType == .other ? customName.trimmed : nil
        cert.certNumber     = certNumber.trimmed.isEmpty  ? nil : certNumber.trimmed
        cert.issuingBody    = issuingBody.trimmed.isEmpty ? nil : issuingBody.trimmed
        cert.issuedDate     = hasIssuedDate ? issuedDate : nil
        cert.expiryDate     = hasExpiry     ? expiryDate : nil
        cert.notes          = notes.trimmed.isEmpty ? nil : notes.trimmed
        cert.documentData   = documentData
        cert.updatedAt      = Date()
        cert.lastModifiedBy = store.currentUser?.fullName ?? ""
        cert.lastModifiedAt = Date()

        store.upsertCertificate(cert)

        // Notify if expiring soon on save
        if cert.status == .expiringSoon, let days = cert.daysUntilExpiry {
            let empName = store.employees.first { $0.id == empID }?.fullName ?? "Worker"
            NotificationManager.shared.notifyExpiringCertificate(
                certificateID: cert.id,
                employeeName:  empName,
                certName:      cert.displayName,
                daysLeft:      days
            )
        }

        dismiss()
    }
}

// MARK: - Employee Certificate Section (for EmployeeDetailView)

struct EmployeeCertificateSection: View {
    let employee: Employee
    @EnvironmentObject var store: AppStore
    @State private var showAdd = false

    private var certs: [Certificate] {
        store.certificates(for: employee.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionHeader(title: "Certifications", count: certs.count)
                Spacer()
                Button { showAdd = true } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3).foregroundColor(.blue)
                }
                .padding(.trailing)
            }

            if certs.isEmpty {
                EmptyCard(message: "No certifications on file.")
            } else {
                VStack(spacing: 8) {
                    ForEach(certs) { cert in
                        NavigationLink {
                            CertificateDetailView(certificate: cert)
                        } label: {
                            EmployeeCertRow(cert: cert)
                                .padding(.horizontal)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            CertificateCreateEditView(prelinkedEmployeeID: employee.id)
        }
    }
}

struct EmployeeCertRow: View {
    let cert: Certificate

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(cert.type.color.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: cert.type.icon)
                    .foregroundColor(cert.type.color)
                    .font(.system(size: 16))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(cert.displayName)
                    .font(.subheadline).bold().lineLimit(1).foregroundColor(.primary)
                if let expiry = cert.expiryDate {
                    let days = cert.daysUntilExpiry ?? 0
                    let label = days < 0
                        ? "Expired \(abs(days))d ago"
                        : "Expires \(expiry.formatted(date: .abbreviated, time: .omitted))"
                    Text(label)
                        .font(.caption2)
                        .foregroundColor(cert.status == .expired ? .red :
                                         cert.status == .expiringSoon ? .orange : .secondary)
                } else {
                    Text("No expiry").font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
            CertStatusBadge(status: cert.status)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Compliance Alert Banner (reusable in dashboards)

struct ComplianceAlertBanner: View {
    @EnvironmentObject var store: AppStore

    private var alerts: [Certificate] { store.complianceAlerts }

    var body: some View {
        if !alerts.isEmpty {
            let expired      = store.expiredCertificates.count
            let expiringSoon = store.expiringCertificates.count
            let parts = [
                expired > 0      ? "\(expired) expired" : nil,
                expiringSoon > 0 ? "\(expiringSoon) expiring soon" : nil
            ].compactMap { $0 }
            NavigationLink { CertificateListView() } label: {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(Color.orange.opacity(0.15)).frame(width: 44, height: 44)
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Certification Compliance Alert")
                            .font(.subheadline).bold().foregroundColor(.primary)
                        Text(parts.joined(separator: " · "))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundColor(.secondary).font(.caption)
                }
                .padding()
                .background(Color.orange.opacity(0.07))
                .cornerRadius(14)
            }
            .accessibilityLabel("Certification compliance alert. \(parts.joined(separator: ", ")).")
            .accessibilityHint("Tap to review all certification issues")
        }
    }
}

// MARK: - Cert Status Badge

struct CertStatusBadge: View {
    let status: CertificateStatus
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: status.icon).font(.caption2)
            Text(status.displayName).font(.caption2).bold()
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(status.color.opacity(0.15))
        .foregroundColor(status.color)
        .cornerRadius(5)
    }
}

// MARK: - String trim helper (local)

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
