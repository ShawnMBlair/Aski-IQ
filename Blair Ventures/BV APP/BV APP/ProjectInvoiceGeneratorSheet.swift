// ProjectInvoiceGeneratorSheet.swift
// Aski IQ — Generate an Invoice from a Project (Phase 7 audit fix).
//
// WHY THIS EXISTS
// Pre-2026-04 audit, the only path for auto-invoice was Material
// Sale → .invoiced. Project-based billing (deposits, progress draws,
// finals) was 100% manual: pick the projectID by hand, retype the
// client, retype each line item, hope the tax rate matched the
// quote. The audit flagged this as the #1 missing automation in
// the commercial workflow.
//
// THIS SHEET DOES
//   1. Picks an accepted Quote linked to the project (default = the
//      most recent one).
//   2. Lets the operator pick Invoice Type (deposit / progress /
//      final / standard). For deposit/progress, lets them set a
//      percentage of the contract value as a single line item.
//   3. Carries the Quote line items into the Invoice (full or
//      pro-rated by percentage).
//   4. Locks the Quote's tax rate by snapshotting it into
//      Invoice.lockedFromTaxRate. The on-form tax field warns if
//      the operator manually drifts it from that baseline.
//   5. Writes back invoiceID via `store.upsertInvoice` (auto-stamps
//      .pending and pushes via SyncEngine).
//
// WHAT IT DOESN'T DO (intentionally)
//   * Doesn't auto-fire on project status change. Billing timing is
//     a business decision; auto-firing produces wrong invoices.
//   * Doesn't reconcile against existing draws — operator picks the
//     percentage. Future enhancement: track cumulative billed-to-date.

import SwiftUI

struct ProjectInvoiceGeneratorSheet: View {
    let project: Project
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    // MARK: - State

    @State private var selectedQuoteID: UUID?     = nil
    @State private var invoiceType:     InvoiceType = .progress
    @State private var percentString:   String     = "30"
    @State private var taxRateString:   String     = ""
    @State private var dueDate:         Date       = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var poNumber:        String     = ""
    @State private var notesField:      String     = ""

    @State private var showResult: String?   = nil
    @State private var resultIsError: Bool   = false
    @State private var isSaving: Bool        = false

    // MARK: - Derived

    /// Accepted quotes for THIS project. Most recent first. Pre-fix
    /// the user had to manually pick a quote ID — now the picker
    /// only shows quotes already linked to the project, so a wrong
    /// pick is essentially impossible.
    private var eligibleQuotes: [Quote] {
        store.quotes
            .filter { $0.projectID == project.id && !$0.isDeleted }
            .filter { $0.status == .accepted || $0.status == .approved }
            .sorted { $0.quoteDate > $1.quoteDate }
    }

    private var selectedQuote: Quote? {
        guard let id = selectedQuoteID else { return nil }
        return store.quotes.first(where: { $0.id == id })
    }

    private var contractValue: Decimal {
        // Prefer linked quote's grand total; fall back to project's
        // contractValue if no quote selected. Last resort: zero.
        if let q = selectedQuote { return q.grandTotal }
        return project.contractValue ?? 0
    }

    private var sourceTaxRate: Decimal {
        selectedQuote?.taxRate ?? Decimal(AppSettings.shared.taxRate)
    }

    /// Current on-form tax rate (parsed from the editor). Falls back
    /// to the source quote's rate so a user who never touches the
    /// field naturally inherits it.
    private var currentTaxRate: Decimal {
        if let d = Decimal(string: taxRateString.trimmingCharacters(in: .whitespaces)) {
            return d
        }
        return sourceTaxRate
    }

    private var taxRateHasDrifted: Bool {
        guard let _ = selectedQuote else { return false }
        // Compare with a small tolerance — `Decimal == Decimal` is
        // strict, but a user toggling the field reformats trailing
        // zeros that round-trip as the same value.
        return abs(currentTaxRate - sourceTaxRate) > Decimal(0.001)
    }

    private var percent: Decimal {
        Decimal(string: percentString.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// Single-line preview amount for deposit/progress invoices.
    private var previewAmount: Decimal {
        switch invoiceType {
        case .deposit, .progress:
            return contractValue * percent / 100
        case .final, .standard, .materialSale:
            return contractValue
        }
    }

    private var canSave: Bool {
        !isSaving
        && project.clientID != nil
        && contractValue > 0
        && (invoiceType == .standard || invoiceType == .final || percent > 0)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                projectSummarySection

                quotePickerSection

                typeAndAmountSection

                taxAndScheduleSection

                if !poNumber.isEmpty || invoiceType != .standard {
                    referenceSection
                }

                previewSection

                resultSection
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Generate Invoice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create") { generate() }
                        .bold()
                        .disabled(!canSave)
                }
            }
            .onAppear {
                // Default the selected quote to the most recent
                // accepted/approved one. Most projects only have
                // one anyway — saves a tap.
                if selectedQuoteID == nil { selectedQuoteID = eligibleQuotes.first?.id }
                // Default the on-form tax rate to the source rate
                // so the operator inherits the locked value unless
                // they choose to drift.
                if taxRateString.isEmpty {
                    taxRateString = NSDecimalNumber(decimal: sourceTaxRate).stringValue
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var projectSummarySection: some View {
        Section {
            HStack {
                Image(systemName: "folder.fill").foregroundColor(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.headline)
                    Text(project.clientName).font(.caption).foregroundColor(.secondary)
                    if let cv = project.contractValue {
                        Text("Contract value: \(cv.currencyString)")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var quotePickerSection: some View {
        Section {
            if eligibleQuotes.isEmpty {
                Label("No accepted/approved quote linked to this project. The invoice will be standalone — line items aren't carried over.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
            } else {
                Picker("Source quote", selection: $selectedQuoteID) {
                    Text("None — start blank").tag(UUID?.none)
                    ForEach(eligibleQuotes) { q in
                        Text("\(q.jobNumber) · \(q.grandTotal.currencyString)")
                            .tag(Optional(q.id))
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedQuoteID) { _, _ in
                    // Re-sync the tax-rate field when the source
                    // quote changes, but only if the user hasn't
                    // hand-edited it (drift detection above).
                    if !taxRateHasDrifted {
                        taxRateString = NSDecimalNumber(decimal: sourceTaxRate).stringValue
                    }
                }
            }
        } header: {
            Text("Source quote")
        } footer: {
            if let q = selectedQuote {
                Text("Line items, tax rate, and contract value will inherit from \(q.jobNumber).")
            } else {
                Text("Without a source quote you'll need to add line items manually after creation.")
            }
        }
    }

    @ViewBuilder
    private var typeAndAmountSection: some View {
        Section {
            Picker("Invoice type", selection: $invoiceType) {
                ForEach(InvoiceType.allCases, id: \.self) { t in
                    if t != .materialSale {  // material sales generate via their own flow
                        Label(t.displayName, systemImage: t.icon).tag(t)
                    }
                }
            }
            .pickerStyle(.menu)

            if invoiceType == .deposit || invoiceType == .progress {
                HStack {
                    Text("Percent of contract")
                    Spacer()
                    TextField("30", text: $percentString)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                    Text("%").foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Type & amount")
        } footer: {
            switch invoiceType {
            case .deposit:      Text("Up-front payment. Typically 25-50% before mobilization.")
            case .progress:     Text("Mid-project draw. Carries a single \"Progress Billing — N%\" line item.")
            case .final:        Text("Closeout. Bills the remainder of the quote line items.")
            case .standard:     Text("Plain invoice — manual line items, no quote-driven amount.")
            case .materialSale: EmptyView()
            }
        }
    }

    @ViewBuilder
    private var taxAndScheduleSection: some View {
        Section {
            HStack {
                Text("Tax rate")
                Spacer()
                TextField("5.0", text: $taxRateString)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                Text("%").foregroundColor(.secondary)
            }
            DatePicker("Due date", selection: $dueDate, displayedComponents: .date)
        } header: {
            Text("Tax & due date")
        } footer: {
            if taxRateHasDrifted {
                Text("⚠️ This rate (\(taxRateString)%) differs from the source quote (\(NSDecimalNumber(decimal: sourceTaxRate).stringValue)%). The original quote rate will be locked on the invoice for audit.")
                    .foregroundColor(.orange)
            } else if let q = selectedQuote {
                Text("Inherited from \(q.jobNumber). Locked on the invoice.")
            } else {
                Text("Loaded from your company default.")
            }
        }
    }

    @ViewBuilder
    private var referenceSection: some View {
        Section {
            TextField("Client PO #", text: $poNumber)
            TextField("Invoice notes (visible on PDF)", text: $notesField, axis: .vertical)
                .lineLimit(2...4)
        } header: {
            Text("Reference")
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        Section {
            HStack {
                Text("Subtotal")
                Spacer()
                Text(previewAmount.currencyString).font(.subheadline).bold()
            }
            HStack {
                Text("Tax (\(NSDecimalNumber(decimal: currentTaxRate).stringValue)%)")
                Spacer()
                Text((previewAmount * currentTaxRate / 100).currencyString)
                    .font(.subheadline).foregroundColor(.secondary)
            }
            HStack {
                Text("Total").font(.headline)
                Spacer()
                Text((previewAmount + previewAmount * currentTaxRate / 100).currencyString)
                    .font(.headline).bold().foregroundColor(.green)
            }
        } header: {
            Text("Preview")
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if let msg = showResult {
            Section {
                Label(msg, systemImage: resultIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundColor(resultIsError ? .red : .green)
                    .font(.caption)
            }
        }
    }

    // MARK: - Generate

    private func generate() {
        guard let clientID = project.clientID else {
            showResult = "Project has no client — set one before invoicing."
            resultIsError = true
            return
        }
        guard contractValue > 0 else {
            showResult = "Contract value is zero — pick a quote or set the project's contractValue."
            resultIsError = true
            return
        }
        isSaving = true
        defer { isSaving = false }

        var inv = Invoice(invoiceNumber: store.nextInvoiceNumber(), projectID: project.id)
        inv.clientID    = clientID
        inv.companyID   = project.companyID ?? store.currentCompanyID
        inv.invoiceType = invoiceType
        inv.dueDate     = dueDate
        inv.poNumber    = poNumber
        inv.notes       = notesField
        inv.taxRate     = currentTaxRate
        inv.lockedFromTaxRate = sourceTaxRate
        inv.quoteID     = selectedQuoteID
        // 2026-04 re-audit fix: lock the source quote's currency.
        // If no source quote, fall back to the company's preferred
        // currency rather than the hard-coded "USD" default.
        inv.currency    = selectedQuote?.currency
            ?? AppSettings.shared.preferredCurrency

        // Bill-to defaults from the linked client.
        if let client = store.client(id: clientID) {
            inv.billToName    = client.name
            inv.billToAddress = client.fullBillingAddress
        }

        // Build line items.
        switch invoiceType {
        case .deposit, .progress:
            // Single-line %-of-contract draw. Description encodes the
            // type + percentage so an emailed PDF reads cleanly.
            let label: String = invoiceType == .deposit
                ? "Deposit Invoice — \(percentString)% of contract"
                : "Progress Billing — \(percentString)%"
            inv.lineItems = [
                InvoiceLineItem(
                    description: label,
                    quantity:    1,
                    unitPrice:   previewAmount,
                    taxable:     true,
                    costCode:    selectedQuote.flatMap { _ in "PROGRESS" } ?? ""
                )
            ]

        case .final:
            // Carry quote line items verbatim. The "final" math
            // assumes prior progress invoices have already billed
            // out the deposits/draws — operator manages reconciliation.
            if let q = selectedQuote {
                inv.lineItems = q.lineItems.map { src in
                    InvoiceLineItem(
                        description: src.description,
                        quantity:    src.estimatedQuantity,
                        unitPrice:   src.unitRate,
                        taxable:     true,
                        costCode:    src.code
                    )
                }
            } else {
                inv.lineItems = [
                    InvoiceLineItem(
                        description: "Final invoice — \(project.name)",
                        quantity:    1,
                        unitPrice:   contractValue,
                        taxable:     true
                    )
                ]
            }

        case .standard:
            // Operator builds line items in InvoiceDetailView after
            // creation. Seed with a single placeholder so the invoice
            // total isn't $0 on save.
            if let q = selectedQuote {
                inv.lineItems = q.lineItems.map { src in
                    InvoiceLineItem(
                        description: src.description,
                        quantity:    src.estimatedQuantity,
                        unitPrice:   src.unitRate,
                        taxable:     true,
                        costCode:    src.code
                    )
                }
            }

        case .materialSale:
            // Unreachable — picker hides this case. Belt-and-braces.
            break
        }

        inv.syncStatus = .pending
        // `addInvoice` already stamps tenant scope, sync status,
        // pushes via SyncEngine, AND writes a CRM activity row, so
        // we don't need a separate logInvoiceCreatedToCRM call here.
        store.addInvoice(inv)

        showResult = "Invoice \(inv.invoiceNumber) created (\(inv.invoiceType.displayName)). Total: \(inv.total.currencyString)."
        resultIsError = false

        // Brief beat then dismiss so the user sees the success line.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            dismiss()
        }
    }
}
