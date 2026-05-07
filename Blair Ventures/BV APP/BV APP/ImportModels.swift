// ImportModels.swift
// Aski IQ – Data Import System (v1.0)

import Foundation
import SwiftUI

// MARK: - Import Status

enum ImportStatus: String, Codable, CaseIterable {
    case draft      = "Draft"
    case validating = "Validating"
    case ready      = "Ready"
    case importing  = "Importing"
    case completed  = "Completed"
    case failed     = "Failed"
    case rolledBack = "Rolled Back"

    var color: Color {
        switch self {
        case .draft:      return .secondary
        case .validating: return .blue
        case .ready:      return .green
        case .importing:  return .orange
        case .completed:  return .green
        case .failed:     return .red
        case .rolledBack: return .purple
        }
    }

    var icon: String {
        switch self {
        case .draft:      return "doc"
        case .validating: return "checkmark.shield"
        case .ready:      return "checkmark.circle"
        case .importing:  return "arrow.up.circle"
        case .completed:  return "checkmark.circle.fill"
        case .failed:     return "xmark.circle.fill"
        case .rolledBack: return "arrow.uturn.backward.circle.fill"
        }
    }
}

// MARK: - Import Action

enum ImportActionType: String, Codable, CaseIterable {
    case create  = "create"
    case update  = "update"
    case archive = "archive"
}

// MARK: - Import Record Types

enum ImportRecordType: String, Codable, CaseIterable, Identifiable {
    // Core
    case companies     = "Company"
    case clients       = "Client"
    case contacts      = "Contact"
    case opportunities = "Opportunity"
    // Operations
    case projects      = "Project"
    case estimates     = "Estimate"
    case estimateLines = "Estimate Line"
    case products      = "Product"
    case vendors       = "Vendor"
    case employees     = "Employee"
    case equipment     = "Equipment"
    case schedules     = "Schedule"
    case timesheets    = "Timesheet"
    // Forms & Docs
    case safetyForms   = "Safety Form"
    case customForms   = "Custom Form"
    case documents     = "Document"
    // Legacy alias
    case forms         = "Form"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .companies:     return "building.2.crop.circle.fill"
        case .clients:       return "building.2.fill"
        case .contacts:      return "person.fill"
        case .opportunities: return "chart.line.uptrend.xyaxis"
        case .projects:      return "folder.fill"
        case .estimates:     return "doc.text.fill"
        case .estimateLines: return "list.number"
        case .products:      return "shippingbox.fill"
        case .vendors:       return "cart.fill"
        case .employees:     return "person.3.fill"
        case .equipment:     return "wrench.and.screwdriver.fill"
        case .schedules:     return "calendar"
        case .timesheets:    return "clock.fill"
        case .safetyForms:   return "cross.case.fill"
        case .customForms:   return "list.clipboard.fill"
        case .documents:     return "paperclip"
        case .forms:         return "list.clipboard.fill"
        }
    }

    var color: Color {
        switch self {
        case .companies:     return .blue
        case .clients:       return .teal
        case .contacts:      return .teal
        case .opportunities: return .teal
        case .projects:      return .green
        case .estimates:     return .green
        case .estimateLines: return .green
        case .products:      return .orange
        case .vendors:       return .orange
        case .employees:     return .indigo
        case .equipment:     return .purple
        case .schedules:     return .indigo
        case .timesheets:    return .indigo
        case .safetyForms:   return .red
        case .customForms:   return .red
        case .documents:     return .brown
        case .forms:         return .red
        }
    }

    /// Enforced relational processing order
    var processingOrder: Int {
        switch self {
        case .companies:     return 1
        case .clients:       return 2
        case .contacts:      return 3
        case .opportunities: return 4
        case .products:      return 5
        case .vendors:       return 6
        case .employees:     return 7
        case .equipment:     return 8
        case .projects:      return 9
        case .estimates:     return 10
        case .estimateLines: return 11
        case .schedules:     return 12
        case .timesheets:    return 13
        case .safetyForms:   return 14
        case .customForms:   return 15
        case .documents:     return 16
        case .forms:         return 17
        }
    }

    var requiredFields: [String] {
        switch self {
        case .companies:     return ["company_name"]
        case .clients:       return ["client_name"]
        case .contacts:      return ["first_name", "last_name"]
        case .opportunities: return ["opportunity_name", "client_name"]
        case .projects:      return ["project_name"]
        case .estimates:     return ["estimate_name"]
        case .estimateLines: return ["estimate_name", "line_number", "description"]
        case .products:      return ["product_name"]
        case .vendors:       return ["vendor_name"]
        case .employees:     return ["first_name", "last_name", "email"]
        case .equipment:     return ["equipment_name"]
        case .schedules:     return ["employee_name", "project_name", "start_date"]
        case .timesheets:    return ["employee_name", "project_name", "date"]
        case .safetyForms:   return ["form_type", "date"]
        case .customForms:   return ["form_template_name", "submission_date"]
        case .documents:     return ["document_name"]
        case .forms:         return ["form_name"]
        }
    }

    var availableFields: [ImportSystemField] {
        // Common trailer fields on every type
        let common: [ImportSystemField] = [
            .init(key: "action_type",   label: "Action (create/update/archive)", required: false),
            .init(key: "app_record_id", label: "App Record ID (for updates)",     required: false),
            .init(key: "external_id",   label: "External / Reference ID",         required: false),
            .init(key: "notes",         label: "Notes",                            required: false),
        ]

        switch self {
        case .clients:
            return [
                .init(key: "client_name",    label: "Client Name",         required: true),
                .init(key: "client_code",    label: "Client Code",         required: false),
                .init(key: "contact_name",   label: "Contact Name",        required: false),
                .init(key: "contact_title",  label: "Contact Title",       required: false),
                .init(key: "contact_email",  label: "Contact Email",       required: false),
                .init(key: "contact_phone",  label: "Contact Phone",       required: false),
                .init(key: "billing_address",label: "Billing Address",     required: false),
                .init(key: "billing_city",   label: "Billing City",        required: false),
                .init(key: "billing_province",label: "Province / State",   required: false),
                .init(key: "billing_postal", label: "Postal / ZIP Code",   required: false),
                .init(key: "payment_terms",  label: "Default Payment Terms",required: false),
                .init(key: "tax_exempt",     label: "Tax Exempt (true/false)",required: false),
            ] + common

        default:
            // For all other types, use the tab registry definition
            let tab = ImportTabRegistry.tab(for: self)
            return tab?.allFields.map { f in
                ImportSystemField(key: f.key, label: f.label, required: f.required)
            } ?? common
        }
    }
}

// MARK: - System Field Definition

struct ImportSystemField: Identifiable, Equatable {
    let key:      String
    let label:    String
    let required: Bool
    var id: String { key }
}

// MARK: - Column Mapping

struct ColumnMapping: Identifiable {
    var id             = UUID()
    var spreadsheetColumn: String    // Raw column header from file
    var systemField:   String?       // Mapped system key, nil = ignore
}

// MARK: - Validation Error / Warning

struct ImportValidationIssue: Identifiable {
    var id          = UUID()
    var rowIndex:   Int
    var field:      String
    var message:    String
    var isBlocking: Bool   // true = error (blocked), false = warning
}

// MARK: - Row State

enum ImportRowState: String {
    case clean   = "Ready"
    case warning = "Warning"
    case error   = "Error"
    case skipped = "Skipped"

    var color: Color {
        switch self {
        case .clean:   return .green
        case .warning: return .orange
        case .error:   return .red
        case .skipped: return .secondary
        }
    }

    var icon: String {
        switch self {
        case .clean:   return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.circle.fill"
        case .skipped: return "minus.circle.fill"
        }
    }
}

// MARK: - Import Row

struct ImportRow: Identifiable {
    var id               = UUID()
    var rowIndex:        Int
    var rawData:         [String: String]   // column header → raw value
    var mappedData:      [String: String]   // systemField key → value
    var issues:          [ImportValidationIssue] = []
    var state:           ImportRowState = .clean
    var isSkipped:       Bool = false
    var existingMatchID: UUID? = nil

    var hasErrors:   Bool { issues.contains { $0.isBlocking  } }
    var hasWarnings: Bool { issues.contains { !$0.isBlocking } }

    var effectiveState: ImportRowState {
        if isSkipped       { return .skipped }
        if hasErrors       { return .error   }
        if hasWarnings     { return .warning }
        return .clean
    }
}

// MARK: - Import Batch (persisted in Supabase)

struct ImportBatch: Identifiable, Codable {
    var id:              UUID   = UUID()
    var companyID:       UUID
    var uploadedBy:      UUID
    var fileName:        String
    var recordType:      String          // ImportRecordType.rawValue
    var status:          ImportStatus    = .draft
    var templateVersion: String          = "v1.0"

    var totalRows:   Int = 0
    var created:     Int = 0
    var updated:     Int = 0
    var skipped:     Int = 0
    var errorCount:  Int = 0

    var createdAt:   Date  = Date()
    var completedAt: Date? = nil

    var canRollback: Bool { status == .completed }
}

// MARK: - Audit Entry

struct ImportAuditEntry: Identifiable, Codable {
    var id:         UUID  = UUID()
    var batchID:    UUID
    var companyID:  UUID
    var uploadedBy: UUID
    var action:     String   // "import_completed", "rollback_initiated", "row_skipped" …
    var detail:     String
    var timestamp:  Date = Date()
}

// MARK: - Import Step

enum ImportStep: Int, CaseIterable {
    case selectType  = 0
    case uploadFile  = 1
    case mapColumns  = 2
    case preview     = 3
    case processing  = 4
    case summary     = 5

    var title: String {
        switch self {
        case .selectType:  return "Select Type"
        case .uploadFile:  return "Upload File"
        case .mapColumns:  return "Map Columns"
        case .preview:     return "Preview"
        case .processing:  return "Importing"
        case .summary:     return "Summary"
        }
    }
}
