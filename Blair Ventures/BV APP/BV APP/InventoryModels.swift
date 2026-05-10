// InventoryModels.swift
// Phase 8 / Inventory v1 — data models matching the
// `migrations/phase8_inventory/INV1_inventory_module_v1_schema.sql`
// table shapes.
//
// Scope per the original deferral note in `Procurement.swift`:
// items, stock locations, quantity on hand, transfers, project/material
// issue-outs. NOT in v1: reservations, low-stock alerts, supplier
// reorder logic, multi-unit conversions, barcode scanning.

import Foundation

// MARK: - InventoryItem

/// Stockable SKU. One row per (company, sku). Optionally linked to a
/// product_service so estimating can suggest "you have this in stock"
/// when a line item picks the matching product.
struct InventoryItem: Identifiable, Codable, Equatable, BaseModel {
    var id: UUID = UUID()
    var externalID: String? = nil
    var companyID: UUID? = nil

    // Required fields
    var sku: String = ""
    var name: String = ""
    var unit: String = "ea"             // 'ea', 'kg', 'l', 'box', 'm', etc.

    // Optional descriptors
    var description: String = ""
    var costCode: String = ""
    var notes: String = ""

    // Optional links
    var productServiceID: UUID? = nil
    var defaultLocationID: UUID? = nil

    // Cost basis snapshot (catalog price for new arrivals; per-location
    // valuation lives on the stock_level row).
    var standardCost: Decimal? = nil

    var isActive: Bool = true

    // BaseModel boilerplate
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date = Date()
    var syncStatus: SyncStatus = .synced
    var isDeleted: Bool = false
    var deletedAt: Date? = nil
    var deletedBy: String? = nil
}

// MARK: - StockLocation

/// Where inventory lives. Yards, warehouses, mobile units. Each company
/// has at least one default location (seeded by INV1 as "Main Yard").
struct StockLocation: Identifiable, Codable, Equatable, BaseModel {
    var id: UUID = UUID()
    var externalID: String? = nil
    var companyID: UUID? = nil

    var name: String = ""
    var code: String = ""               // short code e.g. "MAIN"
    var description: String = ""

    /// 'warehouse', 'yard', 'site_staging', 'mobile'
    var locationType: String = "warehouse"

    var address: String = ""
    var isActive: Bool = true
    var isDefault: Bool = false

    // BaseModel
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date = Date()
    var syncStatus: SyncStatus = .synced
    var isDeleted: Bool = false
    var deletedAt: Date? = nil
    var deletedBy: String? = nil
}

// MARK: - InventoryStockLevel

/// Quantity-on-hand for a specific (item × location) tuple. Updated by:
/// 1) `InventoryTransfer` rows landing — receives bump qty up at the
///    destination, sends bump qty down at the source.
/// 2) Physical counts — direct edits with `lastCountedAt` stamp.
///
/// The avg_unit_cost field tracks weighted-average per location; v2 will
/// add explicit method (avg vs FIFO).
struct InventoryStockLevel: Identifiable, Codable, Equatable, BaseModel {
    var id: UUID = UUID()
    var externalID: String? = nil
    var companyID: UUID? = nil

    var itemID: UUID
    var locationID: UUID

    var quantityOnHand: Decimal = 0
    var avgUnitCost: Decimal? = nil

    var lastCountedAt: Date? = nil
    var lastCountedBy: String = ""
    var notes: String = ""

    // BaseModel
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date = Date()
    var syncStatus: SyncStatus = .synced
    var isDeleted: Bool = false
    var deletedAt: Date? = nil
    var deletedBy: String? = nil
}

// MARK: - InventoryTransfer

/// Movement record. Exactly one of {toLocationID, toProjectID,
/// toMaterialRequestID} is set per row — the DB CHECK constraint
/// enforces this:
///   • toLocationID set:        location-to-location move
///   • toProjectID set:         issue-out to project (qty leaves stock)
///   • toMaterialRequestID set: filled an MR from inventory rather
///                              than purchasing
///
/// The transferNumber follows the BV-XFR-YYYY-NNNN pattern (parsed-max+1
/// + per-(company, year) partial UNIQUE — same as procurement).
struct InventoryTransfer: Identifiable, Codable, Equatable, BaseModel {
    var id: UUID = UUID()
    var externalID: String? = nil
    var companyID: UUID? = nil

    var transferNumber: String = ""

    var itemID: UUID
    var fromLocationID: UUID

    var toLocationID: UUID? = nil
    var toProjectID: UUID? = nil
    var toMaterialRequestID: UUID? = nil

    var quantity: Decimal = 0
    var unitCost: Decimal? = nil
    var notes: String = ""

    var transferredByName: String = ""
    var transferredAt: Date = Date()

    // BaseModel
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date = Date()
    var syncStatus: SyncStatus = .synced
    var isDeleted: Bool = false
    var deletedAt: Date? = nil
    var deletedBy: String? = nil
}

// MARK: - Convenience

/// Destination shape for the transfer creation UI — picks one of three.
enum InventoryTransferDestination: Equatable {
    case location(UUID)
    case project(UUID)
    case materialRequest(UUID)

    var locationID: UUID? {
        if case .location(let id) = self { return id } else { return nil }
    }
    var projectID: UUID? {
        if case .project(let id) = self { return id } else { return nil }
    }
    var materialRequestID: UUID? {
        if case .materialRequest(let id) = self { return id } else { return nil }
    }
}

extension InventoryItem {
    /// Display string for list rows: "[SKU] Name (unit)"
    var displayLabel: String {
        let trimmedSKU = sku.trimmingCharacters(in: .whitespaces)
        if trimmedSKU.isEmpty { return name }
        return "[\(trimmedSKU)] \(name)"
    }
}

extension StockLocation {
    /// Display string: "Main Yard (MAIN)" or just "Main Yard" if no code.
    var displayLabel: String {
        if code.isEmpty { return name }
        return "\(name) (\(code))"
    }
}
