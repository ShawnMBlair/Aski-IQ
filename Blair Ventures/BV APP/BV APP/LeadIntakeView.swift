// LeadIntakeView.swift
// BV APP – Guided multi-step lead intake flow

import SwiftUI
import Foundation

// MARK: - LeadIntakeView

struct LeadIntakeView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var step: Int = 1

    // Step 1 – Company
    @State private var companySearchText: String = ""
    @State private var selectedClientID: UUID? = nil
    @State private var showNewCompanyFields: Bool = false
    @State private var newCompanyName: String = ""
    @State private var newCompanyPhone: String = ""
    @State private var newCompanyEmail: String = ""
    @State private var newCompanyAddress: String = ""
    @State private var companyStep1Error: String? = nil

    // Step 2 – Contact
    @State private var selectedContactID: UUID? = nil
    @State private var showNewContactFields: Bool = false
    @State private var contactFirstName: String = ""
    @State private var contactLastName: String = ""
    @State private var contactTitle: String = ""
    @State private var contactPhone: String = ""
    @State private var contactEmail: String = ""
    @State private var contactIsPrimary: Bool = true
    @State private var contactStep2Error: String? = nil

    // Step 3 – Opportunity
    @State private var oppTitle: String = ""
    @State private var serviceType: String = ""
    @State private var oppValueText: String = ""
    @State private var siteAddress: String = ""
    @State private var includeEstimatedStart: Bool = false
    @State private var estimatedStart: Date = Date()
    @State private var leadSource: LeadSource = .directInquiry
    @State private var oppNotes: String = ""
    @State private var oppStep3Error: String? = nil

    // MARK: - Computed helpers

    private var resolvedCompanyName: String {
        if let cid = selectedClientID,
           let client = store.clients.first(where: { $0.id == cid }) {
            return client.name
        }
        return newCompanyName
    }

    private var resolvedBillingAddress: String {
        if let cid = selectedClientID,
           let client = store.clients.first(where: { $0.id == cid }) {
            return client.fullBillingAddress
        }
        return newCompanyAddress
    }

    private var existingContacts: [CRMContact] {
        guard let cid = selectedClientID else { return [] }
        return store.contacts(for: cid)
    }

    private var duplicateMatches: [Client] {
        let query = showNewCompanyFields ? newCompanyName : companySearchText
        guard query.count >= 2 else { return [] }
        return store.detectDuplicateCompanies(name: query)
    }

    private var searchResults: [Client] {
        guard !companySearchText.isEmpty, selectedClientID == nil, !showNewCompanyFields else { return [] }
        return store.detectDuplicateCompanies(name: companySearchText)
    }

    private var defaultOppTitle: String {
        let co = resolvedCompanyName
        let svc = serviceType
        if co.isEmpty && svc.isEmpty { return "" }
        if svc.isEmpty { return co }
        if co.isEmpty { return svc }
        return "\(co) — \(svc)"
    }

    private var resolvedContactName: String {
        if let cid = selectedContactID,
           let contact = existingContacts.first(where: { $0.id == cid }) {
            return contact.fullName
        }
        let full = "\(contactFirstName) \(contactLastName)".trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? contactFirstName : full
    }

    private var resolvedOppValue: Decimal {
        Decimal(string: oppValueText) ?? 0
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                StepIndicator(currentStep: step, totalSteps: 4,
                              labels: ["Company", "Contact", "Opportunity", "Review"])
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                Divider()

                ScrollView {
                    VStack(spacing: 0) {
                        switch step {
                        case 1: step1View
                        case 2: step2View
                        case 3: step3View
                        case 4: step4View
                        default: EmptyView()
                        }
                    }
                    .padding(.bottom, 32)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(stepTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step == 1 {
                        Button("Cancel") { dismiss() }
                    } else {
                        Button("Back") { step -= 1 }
                    }
                }
            }
        }
    }

    private var stepTitle: String {
        switch step {
        case 1: return "Company"
        case 2: return "Contact"
        case 3: return "Opportunity"
        case 4: return "Review"
        default: return ""
        }
    }

    // MARK: - Step 1: Company

    private var step1View: some View {
        VStack(spacing: 16) {
            // Search field
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Search existing companies…", text: $companySearchText)
                        .autocorrectionDisabled()
                        .onChange(of: companySearchText) {
                            selectedClientID = nil
                            showNewCompanyFields = false
                        }
                    if !companySearchText.isEmpty {
                        Button { companySearchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                        }
                    }
                }
                .padding(12)
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.top, 16)

            // Search results
            if !searchResults.isEmpty && selectedClientID == nil && !showNewCompanyFields {
                VStack(spacing: 0) {
                    ForEach(Array(searchResults.enumerated()), id: \.element.id) { idx, client in
                        Button {
                            selectedClientID = client.id
                            companySearchText = client.name
                            companyStep1Error = nil
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(client.name).font(.subheadline.weight(.medium)).foregroundColor(.primary)
                                    if let addr = client.billingAddress, !addr.isEmpty {
                                        Text(addr).font(.caption).foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                            }
                            .padding(14)
                        }
                        if idx < searchResults.count - 1 {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
            }

            // Selected company confirmation
            if let cid = selectedClientID,
               let client = store.clients.first(where: { $0.id == cid }) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(client.name).font(.subheadline.weight(.semibold))
                        if !client.fullBillingAddress.isEmpty {
                            Text(client.fullBillingAddress).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Button("Change") {
                        selectedClientID = nil
                        companySearchText = ""
                    }
                    .font(.caption)
                    .foregroundColor(.blue)
                }
                .padding(14)
                .background(Color.green.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
            }

            // Create new company section
            if showNewCompanyFields {
                // Duplicate warning
                if !newCompanyName.isEmpty && !duplicateMatches.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(duplicateMatches) { match in
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("A company named \"\(match.name)\" already exists.")
                                        .font(.caption.weight(.medium))
                                    Button("Use it instead") {
                                        selectedClientID = match.id
                                        companySearchText = match.name
                                        showNewCompanyFields = false
                                        newCompanyName = ""
                                    }
                                    .font(.caption)
                                    .foregroundColor(.blue)
                                }
                                Spacer()
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                }

                VStack(spacing: 0) {
                    IntakeField(label: "Company Name *", text: $newCompanyName,
                                placeholder: "Acme Construction Ltd.")
                    Divider().padding(.leading, 14)
                    IntakeField(label: "Phone", text: $newCompanyPhone, placeholder: "555-123-4567",
                                keyboard: .phonePad)
                    Divider().padding(.leading, 14)
                    IntakeField(label: "Email", text: $newCompanyEmail, placeholder: "info@acme.com",
                                keyboard: .emailAddress)
                    Divider().padding(.leading, 14)
                    IntakeField(label: "Billing Address", text: $newCompanyAddress,
                                placeholder: "123 Main St, City, Province")
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
            }

            // Create new company button (when no match selected and not already showing fields)
            if !showNewCompanyFields && selectedClientID == nil {
                Button {
                    showNewCompanyFields = true
                    if !companySearchText.isEmpty {
                        newCompanyName = companySearchText
                    }
                } label: {
                    Label("Create new company", systemImage: "plus.circle")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 16)
            }

            if let err = companyStep1Error {
                Text(err).font(.caption).foregroundColor(.red).padding(.horizontal, 16)
            }

            // Next button
            Button { advanceFromStep1() } label: {
                Text("Next: Contact")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 16)
        }
    }

    private func advanceFromStep1() {
        // Must have either selected a company or have a name typed for a new one
        if selectedClientID == nil {
            guard showNewCompanyFields else {
                companyStep1Error = "Select an existing company or create a new one."
                return
            }
            guard !newCompanyName.trimmingCharacters(in: .whitespaces).isEmpty else {
                companyStep1Error = "Company name is required."
                return
            }
        }
        companyStep1Error = nil
        // Auto-fill site address from company billing address in step 3
        if siteAddress.isEmpty {
            siteAddress = resolvedBillingAddress
        }
        step = 2
    }

    // MARK: - Step 2: Contact

    private var step2View: some View {
        VStack(spacing: 16) {
            // Existing contacts (if company is selected)
            if selectedClientID != nil && !existingContacts.isEmpty && !showNewContactFields {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Existing Contacts").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                        .padding(.horizontal, 16)

                    VStack(spacing: 0) {
                        ForEach(Array(existingContacts.enumerated()), id: \.element.id) { idx, contact in
                            Button {
                                selectedContactID = contact.id
                                contactStep2Error = nil
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(contact.fullName).font(.subheadline.weight(.medium))
                                            .foregroundColor(.primary)
                                        if !contact.title.isEmpty {
                                            Text(contact.title).font(.caption).foregroundColor(.secondary)
                                        }
                                        if !contact.phone.isEmpty || !contact.email.isEmpty {
                                            Text([contact.phone, contact.email].filter { !$0.isEmpty }.joined(separator: " · "))
                                                .font(.caption).foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if selectedContactID == contact.id {
                                        Image(systemName: "checkmark.circle.fill").foregroundColor(.blue)
                                    } else {
                                        Image(systemName: "circle").foregroundColor(.secondary)
                                    }
                                }
                                .padding(14)
                            }
                            if idx < existingContacts.count - 1 {
                                Divider().padding(.leading, 14)
                            }
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                }

                Button {
                    selectedContactID = nil
                    showNewContactFields = true
                } label: {
                    Label("Add new contact", systemImage: "plus.circle")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 16)
            }

            // New contact fields
            if existingContacts.isEmpty || showNewContactFields {
                VStack(spacing: 0) {
                    IntakeField(label: "First Name *", text: $contactFirstName, placeholder: "Jane")
                    Divider().padding(.leading, 14)
                    IntakeField(label: "Last Name", text: $contactLastName, placeholder: "Smith")
                    Divider().padding(.leading, 14)
                    IntakeField(label: "Title", text: $contactTitle, placeholder: "Project Manager")
                    Divider().padding(.leading, 14)
                    IntakeField(label: "Phone", text: $contactPhone, placeholder: "555-123-4567",
                                keyboard: .phonePad)
                    Divider().padding(.leading, 14)
                    IntakeField(label: "Email", text: $contactEmail, placeholder: "jane@company.com",
                                keyboard: .emailAddress)
                    Divider().padding(.leading, 14)
                    Toggle("Primary Contact", isOn: $contactIsPrimary)
                        .padding(14)
                        .font(.subheadline)
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }

            if let err = contactStep2Error {
                Text(err).font(.caption).foregroundColor(.red).padding(.horizontal, 16)
            }

            Button { advanceFromStep2() } label: {
                Text("Next: Opportunity")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 16)
    }

    private func advanceFromStep2() {
        // Validate: must have selected an existing contact OR have firstName
        if selectedContactID == nil {
            guard !contactFirstName.trimmingCharacters(in: .whitespaces).isEmpty else {
                contactStep2Error = "First name is required."
                return
            }
        }
        contactStep2Error = nil
        // Set default opp title if empty
        if oppTitle.isEmpty {
            oppTitle = defaultOppTitle
        }
        step = 3
    }

    // MARK: - Step 3: Opportunity

    private var step3View: some View {
        VStack(spacing: 16) {
            VStack(spacing: 0) {
                IntakeField(label: "Opportunity Title *", text: $oppTitle,
                            placeholder: defaultOppTitle.isEmpty ? "e.g. Acme — Concrete" : defaultOppTitle)
                Divider().padding(.leading, 14)
                IntakeField(label: "Service Type", text: $serviceType,
                            placeholder: "Concrete, Framing, Electrical…")
                    .onChange(of: serviceType) {
                        if oppTitle.isEmpty || oppTitle == defaultOppTitle {
                            oppTitle = defaultOppTitle
                        }
                    }
                Divider().padding(.leading, 14)
                IntakeField(label: "Estimated Value ($)", text: $oppValueText,
                            placeholder: "0.00", keyboard: .decimalPad)
                Divider().padding(.leading, 14)
                IntakeField(label: "Site Address", text: $siteAddress,
                            placeholder: resolvedBillingAddress.isEmpty ? "123 Site Rd" : resolvedBillingAddress)
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.top, 16)

            // Estimated start date
            VStack(spacing: 0) {
                Toggle("Include Estimated Start", isOn: $includeEstimatedStart)
                    .padding(14)
                    .font(.subheadline)
                if includeEstimatedStart {
                    Divider().padding(.leading, 14)
                    DatePicker("Start Date", selection: $estimatedStart, displayedComponents: [.date])
                        .datePickerStyle(.compact)
                        .padding(14)
                        .font(.subheadline)
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)

            // Source picker
            VStack(spacing: 0) {
                HStack {
                    Text("Lead Source").font(.subheadline)
                    Spacer()
                    Picker("Lead Source", selection: $leadSource) {
                        ForEach(LeadSource.allCases, id: \.self) { src in
                            Text(src.rawValue).tag(src)
                        }
                    }
                    .pickerStyle(.menu)
                }
                .padding(14)
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)

            // Notes
            VStack(alignment: .leading, spacing: 6) {
                Text("Notes").font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                TextEditor(text: $oppNotes)
                    .frame(minHeight: 88)
                    .padding(10)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
            }

            if let err = oppStep3Error {
                Text(err).font(.caption).foregroundColor(.red).padding(.horizontal, 16)
            }

            Button { advanceFromStep3() } label: {
                Text("Next: Review")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 16)
        }
    }

    private func advanceFromStep3() {
        guard !oppTitle.trimmingCharacters(in: .whitespaces).isEmpty else {
            oppStep3Error = "Opportunity title is required."
            return
        }
        oppStep3Error = nil
        step = 4
    }

    // MARK: - Step 4: Review

    private var step4View: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                ReviewRow(icon: "building.2.fill", label: "Company", value: resolvedCompanyName)
                Divider().padding(.leading, 44)
                ReviewRow(icon: "person.fill", label: "Contact", value: resolvedContactName.isEmpty ? "—" : resolvedContactName)
                Divider().padding(.leading, 44)
                ReviewRow(icon: "chart.bar.fill", label: "Opportunity", value: oppTitle)
                if resolvedOppValue > 0 {
                    Divider().padding(.leading, 44)
                    ReviewRow(icon: "dollarsign.circle.fill", label: "Value",
                              value: NumberFormatter.currencyFormatter.string(from: resolvedOppValue as NSDecimalNumber) ?? "$0")
                }
                Divider().padding(.leading, 44)
                ReviewRow(icon: "star.fill", label: "Stage", value: OpportunityStage.newLead.rawValue)
                if !siteAddress.isEmpty {
                    Divider().padding(.leading, 44)
                    ReviewRow(icon: "mappin.circle.fill", label: "Site Address", value: siteAddress)
                }
                Divider().padding(.leading, 44)
                ReviewRow(icon: "clock.fill", label: "Follow-Up", value: "Tomorrow (auto-task created)")
                if !leadSource.rawValue.isEmpty {
                    Divider().padding(.leading, 44)
                    ReviewRow(icon: "antenna.radiowaves.left.and.right", label: "Source", value: leadSource.rawValue)
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.top, 16)

            Button { confirmAndCreate() } label: {
                Label("Confirm & Create Lead", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.green)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 16)
        }
    }

    private func confirmAndCreate() {
        // Build company
        var company: Client
        if let cid = selectedClientID,
           let existing = store.clients.first(where: { $0.id == cid }) {
            company = existing
        } else {
            // Phase-2 audit closeout: route through ClientFactory so
            // the new client gets tenant scope, sync status, and the
            // duplicate-name guard the factory enforces. Lead intake
            // is the second-most-trafficked Client creation path.
            do {
                company = try ClientFactory.make(
                    ClientFactory.Input(
                        name:           newCompanyName.trimmingCharacters(in: .whitespaces),
                        contactEmail:   newCompanyEmail.isEmpty ? nil : newCompanyEmail,
                        contactPhone:   newCompanyPhone.isEmpty ? nil : newCompanyPhone,
                        billingAddress: newCompanyAddress.isEmpty ? nil : newCompanyAddress
                    ),
                    store: store
                )
                company.isActive = true
            } catch let err as FactoryError {
                // Surface the duplicate-name / missing-tenant guard
                // back to the user instead of silently failing the
                // lead intake. The CRM intake flow doesn't have a
                // pre-existing toast at this site, so we use the
                // shared ToastService.
                ToastService.shared.error(err.userMessage)
                return
            } catch {
                ToastService.shared.error(error.localizedDescription)
                return
            }
        }

        // Build contact
        var contact: CRMContact
        if let cid = selectedContactID,
           let existing = existingContacts.first(where: { $0.id == cid }) {
            contact = existing
        } else {
            contact = CRMContact(clientID: company.id)
            contact.firstName  = contactFirstName.trimmingCharacters(in: .whitespaces)
            contact.lastName   = contactLastName.trimmingCharacters(in: .whitespaces)
            contact.title      = contactTitle
            contact.phone      = contactPhone
            contact.email      = contactEmail
            contact.isPrimary  = contactIsPrimary
        }

        // Build opportunity
        var opp = CRMOpportunity(clientID: company.id)
        opp.contactID      = contact.id
        opp.title          = oppTitle.trimmingCharacters(in: .whitespaces)
        opp.stage          = .newLead
        opp.value          = resolvedOppValue
        opp.serviceType    = serviceType
        opp.siteAddress    = siteAddress
        opp.source         = leadSource
        opp.notes          = oppNotes
        opp.probability    = OpportunityStage.newLead.defaultProbability
        opp.estimatedStart = includeEstimatedStart ? estimatedStart : nil

        store.createLead(company: company, contact: contact, opportunity: opp)
        dismiss()
    }
}

// MARK: - Step Indicator

private struct StepIndicator: View {
    let currentStep: Int
    let totalSteps: Int
    let labels: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(1...totalSteps, id: \.self) { i in
                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .fill(i <= currentStep ? Color.blue : Color(.systemGray4))
                            .frame(width: 28, height: 28)
                        if i < currentStep {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundColor(.white)
                        } else {
                            Text("\(i)")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(i == currentStep ? .white : .secondary)
                        }
                    }
                    Text(labels[i - 1])
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(i <= currentStep ? .blue : .secondary)
                        .lineLimit(1)
                }
                if i < totalSteps {
                    Rectangle()
                        .fill(i < currentStep ? Color.blue : Color(.systemGray4))
                        .frame(height: 2)
                        .padding(.horizontal, 4)
                        .padding(.top, 13)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: - Intake Field Helper

private struct IntakeField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundColor(.secondary)
            TextField(placeholder, text: $text)
                .keyboardType(keyboard)
                .autocorrectionDisabled(keyboard != .default)
                .textInputAutocapitalization(keyboard == .emailAddress ? .never : .sentences)
                .font(.subheadline)
        }
        .padding(14)
    }
}

// MARK: - Review Row

private struct ReviewRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundColor(.secondary)
                Text(value).font(.subheadline).foregroundColor(.primary)
            }
            Spacer()
        }
        .padding(14)
    }
}

// MARK: - NumberFormatter Extension

private extension NumberFormatter {
    static let currencyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = .current
        return f
    }()
}
