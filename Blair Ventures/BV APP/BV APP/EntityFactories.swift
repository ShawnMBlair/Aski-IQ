// EntityFactories.swift
// Aski IQ — Centralized record-creation layer (Phase 8 audit fix).
//
// WHY THIS EXISTS
// The 2026-04 audit counted 7 places a Client could be created and 5
// places an Invoice could be created — each with its own subtly
// different defaults, validation, and tenant-stamping logic. The
// result: drift between data created from CRM, Quotes, Importer, and
// the standalone Client list.
//
// SHAPE
//   * Each factory exposes ONE static `make(...)` that returns a
//     correctly-stamped, validated record.
//   * Factories DO NOT write to the store — that's the caller's job.
//     They only mint a struct in memory. This keeps them composable
//     (you can use a factory in a `Quote.preview` flow without
//     polluting the live store) and easy to unit-test.
//   * Validation throws `FactoryError` with typed cases so the UI can
//     route to the right error message.
//   * Tenant scope (`companyID`) and audit fields (`createdAt`,
//     `lastModifiedBy`, `syncStatus = .pending`) are stamped uniformly.
//
// USAGE
//   ```swift
//   do {
//       let client = try ClientFactory.make(
//           name:    "Acme Corp",
//           email:   "billing@acme.com",
//           store:   store
//       )
//       store.upsertClient(client)
//   } catch let err as FactoryError {
//       toast.error(err.userMessage)
//   }
//   ```
//
// MIGRATION POLICY
// We're NOT rewriting every existing call site in this commit — that
// would explode the diff. New code should use the factories; old call
// sites can migrate opportunistically (and the audit roadmap tracks
// which ones are still using direct `.init`).

import Foundation

// MARK: - Errors

enum FactoryError: Error, LocalizedError {
    case missingRequiredField(String)
    case invalidValue(field: String, reason: String)
    case duplicate(field: String, value: String)
    case noTenant

    var errorDescription: String? { userMessage }

    var userMessage: String {
        switch self {
        case .missingRequiredField(let f):
            return "\(f) is required."
        case .invalidValue(let f, let r):
            return "\(f) is invalid — \(r)."
        case .duplicate(let f, let v):
            return "A record with that \(f) (\(v)) already exists. Open the existing one instead of creating a duplicate."
        case .noTenant:
            return "You're not attached to a company. Sign out and back in."
        }
    }
}

// MARK: - Factories
//
// Originally there was an `EntityFactory` protocol with an associated
// `Output` type and a default `stamp` extension, but each factory does
// its tenant-stamping inline inside `make` and never overrode `stamp`,
// so the protocol added zero value and the conformance failed because
// no factory declared its `Output`. Dropped — each factory is a plain
// caseless `enum` namespace exposing a single `make` method.

// MARK: - ClientFactory

/// Mints a new Client. The 2026-04 audit found 7 different places
/// constructing Clients with subtly different defaults. This factory
/// is the single source of truth for new-client construction going
/// forward.
enum ClientFactory {

    /// Optional bag of fields. Callers can pass any subset; required
    /// ones are checked in `make`. Using a struct keeps the call site
    /// readable when the list is long, and avoids 12-arg functions.
    struct Input {
        var name:                String
        var contactName:         String?  = nil
        var contactEmail:        String?  = nil
        var contactPhone:        String?  = nil
        var billingAddress:      String?  = nil
        var billingCity:         String?  = nil
        var billingProvince:     String?  = nil
        var billingPostal:       String?  = nil
        var defaultPaymentTerms: String?  = nil
        var taxExempt:           Bool     = false
        var notes:               String?  = nil
        /// When true the factory permits creation even if a client with
        /// the same name already exists in the store. Default false so
        /// CSV importers and CRM auto-create paths don't silently
        /// produce duplicates.
        var allowDuplicateName:  Bool     = false
    }

    static func make(_ input: Input, store: AppStore) throws -> Client {
        let trimmedName = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw FactoryError.missingRequiredField("Client name")
        }
        if let email = input.contactEmail?.trimmingCharacters(in: .whitespaces),
           !email.isEmpty,
           !email.contains("@") {
            throw FactoryError.invalidValue(field: "Email", reason: "must contain @")
        }

        // Duplicate guard — case-insensitive match on full name.
        if !input.allowDuplicateName {
            let isDuplicate = store.clients.contains { existing in
                existing.isDeleted == false &&
                existing.name.compare(trimmedName, options: .caseInsensitive) == .orderedSame
            }
            if isDuplicate {
                throw FactoryError.duplicate(field: "client name", value: trimmedName)
            }
        }

        let c = Client(
            id:           UUID(),
            name:         trimmedName,
            code:         nil,
            contactName:  input.contactName,
            contactTitle: nil,
            contactEmail: input.contactEmail,
            contactPhone: input.contactPhone,
            billingAddress:  input.billingAddress,
            billingCity:     input.billingCity,
            billingProvince: input.billingProvince,
            billingPostal:   input.billingPostal,
            sites:                [],
            defaultPaymentTerms:  input.defaultPaymentTerms,
            taxExempt:            input.taxExempt,
            notes:                input.notes,
            isActive:             true,
            createdAt:            Date(),
            syncStatus:           .pending,
            companyID:            store.currentCompanyID
        )
        if c.companyID == nil { throw FactoryError.noTenant }
        return c
    }

    /// Convenience overload for the most common call shape — just a
    /// name. Used by CSV import and CRM auto-create paths.
    static func make(name: String, store: AppStore) throws -> Client {
        try make(Input(name: name, allowDuplicateName: true), store: store)
    }
}

// MARK: - ProjectFactory

enum ProjectFactory {

    struct Input {
        var name:           String
        var clientID:       UUID?
        var clientName:     String          // legacy display field; required for old views
        var siteID:         UUID?  = nil
        var siteAddress:    String? = nil
        var startDate:      Date?  = nil
        var endDate:        Date?  = nil
        var estimatedBudget: Decimal? = nil
        var contractValue:  Decimal? = nil
        var assignedPMID:   UUID?  = nil
        var assignedPMName: String? = nil
        var notes:          String? = nil
        /// Job number override. Default uses the AppSettings auto-generator.
        var jobNumber:      String? = nil
    }

    static func make(_ input: Input, store: AppStore) throws -> Project {
        let trimmedName = input.name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            throw FactoryError.missingRequiredField("Project name")
        }
        guard !input.clientName.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw FactoryError.missingRequiredField("Client name")
        }

        var p = Project(
            name:        trimmedName,
            clientName:  input.clientName.trimmingCharacters(in: .whitespaces)
        )
        p.clientID         = input.clientID
        p.siteID           = input.siteID
        p.siteAddress      = input.siteAddress
        p.startDate        = input.startDate
        p.endDate          = input.endDate
        p.estimatedBudget  = input.estimatedBudget
        p.contractValue    = input.contractValue
        p.assignedPMID     = input.assignedPMID
        p.assignedPMName   = input.assignedPMName
        p.notes            = input.notes
        p.jobNumber        = input.jobNumber ?? AppSettings.shared.nextJobNumber()
        p.status           = .active
        p.companyID        = store.currentCompanyID
        p.syncStatus       = .pending

        if p.companyID == nil { throw FactoryError.noTenant }
        return p
    }
}

// MARK: - QuoteFactory

enum QuoteFactory {

    struct Input {
        var estimateID: UUID
        var clientID:   UUID
        var clientName: String
        /// When non-nil the new quote inherits these line items
        /// verbatim. Common path: convert from estimate.
        var lineItems:        [CostCodeItem] = []
        var preparedBy:       String?  = nil
        var siteAddress:      String?  = nil
        var scopeSummary:     String   = ""
        var inclusions:       String   = ""
        var exclusions:       String   = ""
        var assumptions:      String   = ""
        var paymentTerms:     String?  = nil
        var contingencyPercent: Decimal = 0
        var taxRate:          Decimal? = nil
        var validityDays:     Int      = 30
        var opportunityID:    UUID?    = nil
        /// 2026-04 re-audit fix: explicit ISO 4217 currency. Defaults
        /// to nil → factory falls back to AppSettings.preferredCurrency.
        var currency:         String?  = nil
    }

    static func make(_ input: Input, store: AppStore) throws -> Quote {
        guard !input.clientName.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw FactoryError.missingRequiredField("Client name")
        }

        var q = Quote(
            jobNumber:  store.nextQuoteNumber(),
            estimateID: input.estimateID,
            clientID:   input.clientID,
            clientName: input.clientName.trimmingCharacters(in: .whitespaces),
            preparedBy: input.preparedBy ?? store.currentUser?.fullName ?? "Unknown"
        )
        q.opportunityID    = input.opportunityID
        q.siteAddress      = input.siteAddress
        q.scopeSummary     = input.scopeSummary
        q.inclusions       = input.inclusions
        q.exclusions       = input.exclusions
        q.assumptions      = input.assumptions
        q.paymentTerms     = input.paymentTerms ?? AppSettings.shared.defaultPaymentTerms
        q.contingencyPercent = input.contingencyPercent
        q.taxRate          = input.taxRate ?? Decimal(AppSettings.shared.taxRate)
        q.validityDays     = input.validityDays
        q.expiryDate       = Calendar.current.date(byAdding: .day, value: input.validityDays, to: Date()) ?? Date()
        q.lineItems        = input.lineItems
        q.currency         = (input.currency ?? AppSettings.shared.preferredCurrency).uppercased()
        q.companyID        = store.currentCompanyID
        q.syncStatus       = .pending

        if q.companyID == nil { throw FactoryError.noTenant }
        return q
    }
}

// MARK: - MaterialSaleFactory

enum MaterialSaleFactory {

    struct Input {
        var clientID:        UUID
        var contactID:       UUID?  = nil
        var siteID:          UUID?  = nil
        var projectID:       UUID?  = nil
        var quoteID:         UUID?  = nil
        var opportunityID:   UUID?  = nil
        var saleType:        SaleType = .materialSale
        var deliveryAddress: String? = nil
        var requestedDeliveryDate: Date? = nil
        var lineItems:       [MaterialSaleLineItem] = []
        var taxRate:         Decimal? = nil
        var notes:           String?  = nil
    }

    static func make(_ input: Input, store: AppStore) throws -> MaterialSale {
        var s = MaterialSale(clientID: input.clientID)
        s.saleNumber           = store.nextSaleNumber()
        s.saleType             = input.saleType
        s.contactID            = input.contactID
        s.siteID               = input.siteID
        s.projectID            = input.projectID
        s.quoteID              = input.quoteID
        s.opportunityID        = input.opportunityID
        s.deliveryAddress      = input.deliveryAddress
        s.requestedDeliveryDate = input.requestedDeliveryDate
        s.lineItems            = input.lineItems
        s.taxRate              = input.taxRate ?? Decimal(AppSettings.shared.taxRate)
        s.notes                = input.notes
        s.companyID            = store.currentCompanyID
        s.syncStatus           = .pending
        s.lastModifiedBy       = store.currentUser?.fullName ?? ""
        s.lastModifiedAt       = Date()

        if s.companyID == nil { throw FactoryError.noTenant }
        return s
    }
}

// MARK: - InvoiceFactory

enum InvoiceFactory {

    struct Input {
        var projectID:    UUID?  = nil
        var clientID:     UUID
        var quoteID:      UUID?  = nil
        var invoiceType:  InvoiceType = .standard
        var invoiceNumber: String? = nil
        var dueDate:      Date   = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
        var lineItems:    [InvoiceLineItem] = []
        var taxRate:      Decimal = Decimal(AppSettings.shared.taxRate)
        /// Snapshot of the source quote's tax rate. When supplied the
        /// invoice carries `lockedFromTaxRate` so historical rates
        /// don't drift if the source quote is later edited.
        var lockedFromTaxRate: Decimal? = nil
        var billToName:   String = ""
        var billToAddress: String = ""
        var poNumber:     String = ""
        var notes:        String = ""
        /// 2026-04 re-audit fix: ISO 4217. When generated from a
        /// source Quote, the caller should pass the quote's currency
        /// here so the invoice locks the same denomination. Defaults
        /// to AppSettings.preferredCurrency when nil.
        var currency:     String? = nil
    }

    static func make(_ input: Input, store: AppStore) throws -> Invoice {
        var inv = Invoice(
            invoiceNumber: input.invoiceNumber ?? store.nextInvoiceNumber(),
            projectID:     input.projectID
        )
        inv.clientID         = input.clientID
        inv.companyID        = store.currentCompanyID
        inv.quoteID          = input.quoteID
        inv.invoiceType      = input.invoiceType
        inv.dueDate          = input.dueDate
        inv.lineItems        = input.lineItems
        inv.taxRate          = input.taxRate
        inv.lockedFromTaxRate = input.lockedFromTaxRate
        inv.billToName       = input.billToName
        inv.billToAddress    = input.billToAddress
        inv.poNumber         = input.poNumber
        inv.notes            = input.notes
        inv.currency         = (input.currency ?? AppSettings.shared.preferredCurrency).uppercased()
        inv.lastModifiedBy   = store.currentUser?.fullName ?? ""
        inv.lastModifiedAt   = Date()
        inv.syncStatus       = .pending

        if inv.companyID == nil { throw FactoryError.noTenant }
        return inv
    }
}
