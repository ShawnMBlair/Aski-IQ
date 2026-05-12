// MaterialSale.swift
// AskiCommand — Material Sale Module
// Standalone commercial workflow that does not require a project.
// Supports: product/material sales, rentals, service work, direct invoicing.

import Foundation
import SwiftUI

// MARK: - Sale Type

enum SaleType: String, Codable, CaseIterable {
    case projectWork   = "project_work"
    case serviceWork   = "service_work"
    case materialSale  = "material_sale"
    case rental        = "rental"
    case directInvoice = "direct_invoice"

    var displayName: String {
        switch self {
        case .projectWork:   return "Project Work"
        case .serviceWork:   return "Service Work"
        case .materialSale:  return "Material Sale"
        case .rental:        return "Rental"
        case .directInvoice: return "Direct Invoice"
        }
    }

    var icon: String {
        switch self {
        case .projectWork:   return "folder.fill"
        case .serviceWork:   return "wrench.and.screwdriver.fill"
        case .materialSale:  return "shippingbox.fill"
        case .rental:        return "clock.badge.checkmark"
        case .directInvoice: return "doc.plaintext.fill"
        }
    }

    var colorName: String {
        switch self {
        case .projectWork:   return "blue"
        case .serviceWork:   return "orange"
        case .materialSale:  return "purple"
        case .rental:        return "teal"
        case .directInvoice: return "green"
        }
    }

    /// SwiftUI Color matching `colorName`.
    var color: Color {
        switch self {
        case .projectWork:   return .blue
        case .serviceWork:   return .orange
        case .materialSale:  return .purple
        case .rental:        return .teal
        case .directInvoice: return .green
        }
    }

    /// True for types that route to EstimateCreateView instead of MaterialSaleCreateView.
    var usesEstimateFlow: Bool {
        self == .projectWork || self == .serviceWork
    }

    /// v1.1 routing — until dedicated Service-Work and Rental modules
    /// ship in v1.2, these two work types fall back to the standard
    /// project flow. Used by `OpportunityLinksSection` to decide
    /// whether to show the Create Estimate / Create Quote buttons.
    /// `materialSale` users go through the existing Material Sales card;
    /// `directInvoice` users go straight to invoice creation (v1.2).
    var routesToProjectFlowInV1_1: Bool {
        switch self {
        case .projectWork, .serviceWork, .rental: return true
        case .materialSale, .directInvoice:        return false
        }
    }

    /// User-facing hint shown when this work type does NOT route through
    /// the project flow — tells the user where to convert this opp.
    /// Returns nil for types that follow the standard estimate/quote/
    /// project path (no hint needed).
    var conversionHint: String? {
        switch self {
        case .materialSale:
            return "Tap “New Material Sale” below to convert this opportunity."
        case .directInvoice:
            return "Direct-invoice flow ships in v1.2. For v1.1, create an Invoice from the Invoices tab and link this opportunity manually."
        case .projectWork, .serviceWork, .rental:
            return nil
        }
    }

    /// v1.1 — one-line description of where this work type routes
    /// downstream once the opportunity converts. Surfaced in the New
    /// Opportunity picker footer and the workTypeChanged audit log so
    /// users understand the impact of their choice. v1.1 routing keeps
    /// service_work and rental on the project flow as fallbacks until
    /// their dedicated modules ship in v1.2.
    var routingDescription: String {
        switch self {
        case .projectWork:
            return "Opportunity → Estimate → Quote → Project → Progress Invoices"
        case .serviceWork:
            return "Opportunity → Work Order → Invoice (uses Project flow in v1.1)"
        case .materialSale:
            return "Opportunity → Material Sale → Quote/Order/Invoice"
        case .rental:
            return "Opportunity → Rental Record → Return Tracking → Invoice (uses Project flow in v1.1)"
        case .directInvoice:
            return "Opportunity → Invoice (skip Estimate + Quote)"
        }
    }

    /// Forward-compat decode fallback. If the server one day returns a
    /// 6th value (e.g. `equipment_lease`) iOS logs the unknown raw and
    /// defaults to `.projectWork` rather than crashing. Same pattern
    /// as UserRole's unknown-role handler.
    static func decoded(from raw: String) -> SaleType {
        if let known = SaleType(rawValue: raw) { return known }
        #if DEBUG
        print("⚠️ SaleType: unknown raw '\(raw)' — defaulting to projectWork")
        #endif
        return .projectWork
    }
}

// MARK: - Material Sale Status

enum MaterialSaleStatus: String, Codable, CaseIterable {
    case draft     = "draft"
    case quoted    = "quoted"
    case ordered   = "ordered"
    case invoiced  = "invoiced"
    case paid      = "paid"
    case cancelled = "cancelled"

    var displayName: String {
        switch self {
        case .draft:     return "Draft"
        case .quoted:    return "Quoted"
        case .ordered:   return "Ordered"
        case .invoiced:  return "Invoiced"
        case .paid:      return "Paid"
        case .cancelled: return "Cancelled"
        }
    }

    var colorName: String {
        switch self {
        case .draft:     return "secondary"
        case .quoted:    return "blue"
        case .ordered:   return "orange"
        case .invoiced:  return "purple"
        case .paid:      return "green"
        case .cancelled: return "gray"
        }
    }

    var isActive: Bool { ![.paid, .cancelled].contains(self) }
}

// MARK: - Material Sale Line Item
// Product-oriented line item: description, qty, unit price → total.

struct MaterialSaleLineItem: Codable, Identifiable, Equatable {
    var id:               UUID    = UUID()
    var description:      String  = ""
    var quantity:         Decimal = 1
    var unit:             String  = "ea"
    var unitPrice:        Decimal = 0
    var notes:            String  = ""
    var productServiceID: UUID?   = nil   // Optional product library back-link

    var lineTotal: Decimal { quantity * unitPrice }
}

// MARK: - Material Sale

struct MaterialSale: BaseModel {
    static func == (lhs: MaterialSale, rhs: MaterialSale) -> Bool { lhs.id == rhs.id }

    // MARK: BaseModel
    var id:             UUID   = UUID()
    var externalID:     String? = nil
    var companyID:      UUID?  = nil
    var createdAt:      Date   = Date()
    var updatedAt:      Date   = Date()
    var syncStatus:     SyncStatus = .local
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date   = Date()

    // ── Identity ──────────────────────────────────────────
    var saleNumber:  String            = ""              // MS-YYYY-NNNN
    var saleType:    SaleType          = .materialSale
    var status:      MaterialSaleStatus = .draft

    // ── Relationships ─────────────────────────────────────
    var clientID:      UUID
    var contactID:     UUID?  = nil
    var siteID:        UUID?  = nil
    var opportunityID: UUID?  = nil   // Always linked before quote/invoice is created
    var quoteID:       UUID?  = nil   // Quote generated from this sale
    var invoiceID:     UUID?  = nil   // Invoice generated from this sale
    var projectID:     UUID?  = nil   // Optional — only for project-linked sales

    // ── Delivery / Logistics ──────────────────────────────
    var deliveryAddress:       String? = nil
    var requestedDeliveryDate: Date?   = nil

    // ── Terms & Conditions ───────────────────────────────
    /// One-shot ledger flag — flips to true the first time defaults
    /// are auto-attached. Mirrors `Quote.termsDefaultApplied`.
    var termsDefaultApplied: Bool = false

    // ── Customer Acceptance (magic link) ─────────────────
    /// Stamped by `accept_material_sale_via_token` RPC when the
    /// customer clicks the magic-link acceptance page and signs.
    /// Mirrors `Quote.acceptedAt`. Pull-only on the iOS side —
    /// never set from a manual mark-as-accepted flow.
    var acceptedAt: Date? = nil

    // ── Pricing ───────────────────────────────────────────
    var lineItems: [MaterialSaleLineItem] = []
    var taxRate:   Decimal = 0           // e.g. 5.0 = 5% GST

    // ── Notes ─────────────────────────────────────────────
    var notes: String? = nil

    // ── Computed Totals ───────────────────────────────────
    var subtotal:   Decimal { lineItems.reduce(0) { $0 + $1.lineTotal } }
    var taxAmount:  Decimal { subtotal * taxRate / 100 }
    var grandTotal: Decimal { subtotal + taxAmount }

    // ── Soft Delete ───────────────────────────────────────
    var isDeleted: Bool   = false
    var deletedAt: Date?  = nil
    var deletedBy: String? = nil

    // MARK: Sample data tracking
    var isSampleData:           Bool      = false
    var sampleDataBatchID:      UUID?     = nil
    var sampleDataSeedVersion:  String?   = nil
    var sampleDataCreatedAt:    Date?     = nil
    var sampleDataCreatedBy:    UUID?     = nil

    init(clientID: UUID) {
        self.clientID = clientID
    }
}

// MARK: - Sample-data tracking
extension MaterialSale: SampleDataTrackable {}
