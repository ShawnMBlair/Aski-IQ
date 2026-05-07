// Form.swift
// FieldOS – Forms Module (Full Form Builder)

import Foundation
import SwiftUI

// MARK: - Form Field Type

enum FormFieldType: String, Codable, CaseIterable {
    // Layout
    case sectionHeader      // Bold heading that groups fields visually
    case instructions       // Read-only descriptive text block

    // Input
    case shortText          // Single-line text
    case longText           // Multi-line paragraph
    case number             // Numeric input with optional unit label
    case date               // Date picker
    case time               // Time picker
    case dateTime           // Date + time picker

    // Choice
    case yesNo              // Two-segment: Yes / No
    case yesNoNA            // Three-segment: Yes / No / N/A
    case passFail           // Two-segment: Pass / Fail
    case passFailNA         // Three-segment: Pass / Fail / N/A
    case singleChoice       // Radio-style — pick one
    case multipleChoice     // Checkbox-style — pick many
    case dropdown           // Picker/menu — pick one

    // Scale
    case rating             // Star or number rating (configurable 1–5 or 1–10)
    case slider             // Continuous value between min and max

    // Media
    case photo              // Camera / photo library
    case signature          // Finger-draw signature canvas
    case scan               // Document camera scan → stores image + extracted text

    // Data
    case location           // Capture GPS coordinates + address

    // Legacy alias
    case text               // = shortText (kept for backward compat)
}

// MARK: - Field Type Metadata

extension FormFieldType {
    var displayName: String {
        switch self {
        case .sectionHeader:    return "Section Header"
        case .instructions:     return "Instructions"
        case .shortText, .text: return "Short Text"
        case .longText:         return "Long Text"
        case .number:           return "Number"
        case .date:             return "Date"
        case .time:             return "Time"
        case .dateTime:         return "Date & Time"
        case .yesNo:            return "Yes / No"
        case .yesNoNA:          return "Yes / No / N/A"
        case .passFail:         return "Pass / Fail"
        case .passFailNA:       return "Pass / Fail / N/A"
        case .singleChoice:     return "Single Choice"
        case .multipleChoice:   return "Multiple Choice"
        case .dropdown:         return "Dropdown"
        case .rating:           return "Rating"
        case .slider:           return "Slider"
        case .photo:            return "Photo"
        case .signature:        return "Signature"
        case .scan:             return "Document Scan"
        case .location:         return "GPS Location"
        }
    }

    var icon: String {
        switch self {
        case .sectionHeader:    return "text.justify"
        case .instructions:     return "info.circle"
        case .shortText, .text: return "text.alignleft"
        case .longText:         return "doc.text"
        case .number:           return "number"
        case .date:             return "calendar"
        case .time:             return "clock"
        case .dateTime:         return "calendar.badge.clock"
        case .yesNo:            return "checkmark.circle"
        case .yesNoNA:          return "checkmark.circle.badge.questionmark"
        case .passFail:         return "checkmark.shield"
        case .passFailNA:       return "checkmark.shield.fill"
        case .singleChoice:     return "circle.inset.filled"
        case .multipleChoice:   return "list.bullet"
        case .dropdown:         return "chevron.up.chevron.down"
        case .rating:           return "star"
        case .slider:           return "slider.horizontal.3"
        case .photo:            return "camera"
        case .signature:        return "signature"
        case .scan:             return "doc.viewfinder"
        case .location:         return "location"
        }
    }

    var category: FieldTypeCategory {
        switch self {
        case .sectionHeader, .instructions:
            return .layout
        case .shortText, .longText, .number, .date, .time, .dateTime, .text:
            return .input
        case .yesNo, .yesNoNA, .passFail, .passFailNA, .singleChoice, .multipleChoice, .dropdown:
            return .choice
        case .rating, .slider:
            return .scale
        case .photo, .signature, .scan:
            return .media
        case .location:
            return .data
        }
    }

    /// Layout fields don't collect a user response
    var isLayoutOnly: Bool {
        self == .sectionHeader || self == .instructions
    }
}

enum FieldTypeCategory: String {
    case layout   = "Layout"
    case input    = "Input"
    case choice   = "Choice"
    case scale    = "Scale"
    case media    = "Media"
    case data     = "Data"
}

// MARK: - Conditional Logic

/// Show/hide this field based on another field's response
struct FieldCondition: Codable {
    /// The field whose value we check
    var triggerFieldID: UUID
    /// The operator
    var op: ConditionOperator
    /// The expected value (as string, parsed per field type)
    var value: String
}

enum ConditionOperator: String, Codable, CaseIterable {
    case equals         = "equals"
    case notEquals      = "not_equals"
    case contains       = "contains"
    case isYes          = "is_yes"
    case isNo           = "is_no"
    case isFail         = "is_fail"
    case isPass         = "is_pass"
    case greaterThan    = "greater_than"
    case lessThan       = "less_than"

    var displayName: String {
        switch self {
        case .equals:       return "equals"
        case .notEquals:    return "does not equal"
        case .contains:     return "contains"
        case .isYes:        return "is Yes"
        case .isNo:         return "is No"
        case .isFail:       return "is Fail"
        case .isPass:       return "is Pass"
        case .greaterThan:  return "is greater than"
        case .lessThan:     return "is less than"
        }
    }
}

// MARK: - Column Width (Salus col-xs-6 / col-xs-12)

enum ColumnWidth: String, Codable, CaseIterable {
    case full = "full"      // col-xs-12  — one field per row
    case half = "half"      // col-xs-6   — two fields side by side

    var displayName: String {
        switch self {
        case .full: return "Full Width"
        case .half: return "Half Width"
        }
    }
    var icon: String {
        switch self {
        case .full: return "rectangle"
        case .half: return "rectangle.split.2x1"
        }
    }
}

// MARK: - Auto-Variable (Salus variable fields)

/// Fields that auto-populate from the current session context
enum AutoVariable: String, Codable, CaseIterable {
    case currentDate     = "current_date"
    case currentTime     = "current_time"
    case currentDateTime = "current_datetime"
    case userName        = "user_name"       // logged-in employee name
    case userRole        = "user_role"       // foreman, office, etc.
    case siteName        = "site_name"       // project name
    case siteAddress     = "site_address"    // project address
    case companyName     = "company_name"

    // Weather auto-variables (filled from WeatherService)
    case weatherCondition = "weather_condition"  // e.g. "Clear Sky"
    case weatherTemp      = "weather_temp"       // e.g. "22°C"
    case weatherWind      = "weather_wind"       // e.g. "15 km/h NW"
    case weatherHumidity  = "weather_humidity"   // e.g. "65%"
    case weatherSummary   = "weather_summary"    // full one-liner

    var displayName: String {
        switch self {
        case .currentDate:       return "Today's Date"
        case .currentTime:       return "Current Time"
        case .currentDateTime:   return "Date & Time"
        case .userName:          return "Supervisor / User Name"
        case .userRole:          return "User Role"
        case .siteName:          return "Project / Site Name"
        case .siteAddress:       return "Site Address"
        case .companyName:       return "Company Name"
        case .weatherCondition:  return "Weather Condition"
        case .weatherTemp:       return "Temperature"
        case .weatherWind:       return "Wind Speed & Direction"
        case .weatherHumidity:   return "Humidity"
        case .weatherSummary:    return "Full Weather Summary"
        }
    }
    var icon: String {
        switch self {
        case .currentDate, .currentDateTime: return "calendar"
        case .currentTime:       return "clock"
        case .userName:          return "person"
        case .userRole:          return "person.badge.key"
        case .weatherCondition:  return "cloud.sun.fill"
        case .weatherTemp:       return "thermometer.medium"
        case .weatherWind:       return "wind"
        case .weatherHumidity:   return "humidity.fill"
        case .weatherSummary:    return "cloud.fill"
        case .siteName:         return "mappin"
        case .siteAddress:      return "map"
        case .companyName:      return "building.2"
        }
    }
}

// MARK: - Field Edit Permission (Salus allow_editing)

enum FieldPermission: String, Codable, CaseIterable {
    case all        = "all"         // anyone can edit
    case adminOnly  = "admin"       // office/manager only
    case none       = "none"        // read-only / auto-filled label

    var displayName: String {
        switch self {
        case .all:       return "Everyone"
        case .adminOnly: return "Admin Only"
        case .none:      return "Read Only"
        }
    }
}

// MARK: - Field Group (Salus structure.main.groups)

/// A named group that owns an ordered list of field IDs — renders as a titled section
struct FieldGroup: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String                    // Group heading shown on the form
    var fieldIDs: [UUID] = []           // Ordered field references
    var isVisible: Bool = true
    var visibleLogic: FieldCondition?   // Hide entire group conditionally
}

// MARK: - Form Field Definition

struct FormField: Codable, Identifiable {
    var id: UUID = UUID()
    var label: String
    var type: FormFieldType
    var isRequired: Bool = false
    var sortOrder: Int = 0

    // Layout
    var columnWidth: ColumnWidth = .full     // half = side-by-side with next field

    // Auto-populate from session context (Salus `variable`)
    var autoVariable: AutoVariable? = nil   // nil = user must enter manually

    // Edit permission (Salus `allow_editing`)
    var permission: FieldPermission = .all

    // Optional helper text shown beneath the label
    var hint: String?

    // For choice types
    var options: [String]?

    // For number with unit (e.g. "meters", "kg", "°C")
    var unit: String?

    // For rating
    var ratingMax: Int = 5

    // For slider
    var sliderMin: Double = 0
    var sliderMax: Double = 10
    var sliderStep: Double = 1
    var sliderMinLabel: String?
    var sliderMaxLabel: String?

    // For section header / instructions — body text
    var bodyText: String?

    // Conditional visibility
    var condition: FieldCondition?

    // Styling
    var isBold: Bool = false

    /// True if this field cannot be interacted with by the current user
    func isReadOnly(for role: UserRole) -> Bool {
        switch permission {
        case .all:       return false
        case .none:      return true
        case .adminOnly: return role == .fieldWorker || role == .foreman
        }
    }
}

// MARK: - Form Template

struct FormTemplate: BaseModel {
    static func == (lhs: FormTemplate, rhs: FormTemplate) -> Bool { lhs.id == rhs.id }

    var id: UUID = UUID()
    var externalID: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var syncStatus: SyncStatus = .local
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date = Date()

    /// Multi-tenant scope — form templates are org-wide, derived from
    /// `currentCompanyID` on upsert. Required NOT NULL server-side.
    var companyID: UUID? = nil

    var name: String
    var category: String?

    /// Flat field definitions (keyed by sortOrder)
    var fields: [FormField] = []

    /// Optional groups — if populated, overrides flat sortOrder for display
    /// Mirrors Salus structure.main.groups
    var groups: [FieldGroup] = []

    var isActive:      Bool    = true
    var isArchived:    Bool    = false
    var requiresSignature: Bool = false
    var formDescription: String?
    var version:       Int     = 1
    var isDeleted:     Bool    = false
    var deletedAt:     Date?   = nil
    var deletedBy:     String? = nil

    /// Returns fields in display order, respecting groups if defined
    var orderedFields: [FormField] {
        if groups.isEmpty {
            return fields.sorted { $0.sortOrder < $1.sortOrder }
        }
        var result: [FormField] = []
        for group in groups {
            for fid in group.fieldIDs {
                if let f = fields.first(where: { $0.id == fid }) {
                    result.append(f)
                }
            }
        }
        // Append any fields not in a group
        let grouped = Set(groups.flatMap { $0.fieldIDs })
        result += fields.filter { !grouped.contains($0.id) }.sorted { $0.sortOrder < $1.sortOrder }
        return result
    }
}

// MARK: - Three-State Answer (Yes/No/NA, Pass/Fail/NA)

enum ThreeStateAnswer: String, Codable {
    case yes    = "yes"
    case no     = "no"
    case na     = "n/a"
    case pass   = "pass"
    case fail   = "fail"
}

// MARK: - GPS Location Response

struct LocationResponse: Codable {
    var latitude: Double
    var longitude: Double
    var address: String?
}

// MARK: - Form Field Response

struct FormFieldResponse: Codable, Identifiable {
    var id: UUID = UUID()
    var fieldID: UUID

    // Text / Long Text / Instructions
    var textValue: String?

    // Number
    var numberValue: Decimal?

    // Yes/No, Pass/Fail (bool-based)
    var boolValue: Bool?

    // Yes/No/NA, Pass/Fail/NA (three-state)
    var threeStateValue: ThreeStateAnswer?

    // Single / Multiple choice + Dropdown
    var selectedOptions: [String]?

    // Date, Time, DateTime
    var dateValue: Date?

    // Rating (stored as Int)
    var ratingValue: Int?

    // Slider (stored as Double)
    var sliderValue: Double?

    // Photo attachment IDs (references to stored images)
    var photoAttachmentIDs: [UUID] = []

    // Actual photo data (stored locally, uploaded to Supabase Storage on sync)
    var photoData: [Data] = []

    // Supabase Storage object paths for uploaded photos (set after successful upload)
    var photoStorageKeys: [String] = []

    // Signature PNG data
    var signatureData: Data?

    // Supabase Storage object path for uploaded signature (set after successful upload)
    var signatureStorageKey: String?

    // GPS location
    var locationValue: LocationResponse?
}

// MARK: - Form Link Type

/// What entity this form submission is tied to
enum FormLinkType: String, Codable, CaseIterable {
    case none     = "none"
    case project  = "project"
    case site     = "site"
    case office   = "office"
    case location = "location"

    var displayName: String {
        switch self {
        case .none:     return "None"
        case .project:  return "Project"
        case .site:     return "Site"
        case .office:   return "Office"
        case .location: return "Location"
        }
    }

    var icon: String {
        switch self {
        case .none:     return "minus.circle"
        case .project:  return "folder.fill"
        case .site:     return "mappin.and.ellipse"
        case .office:   return "building.2.fill"
        case .location: return "location.fill"
        }
    }

    var color: String {   // use in SwiftUI as Color(hex:) or named
        switch self {
        case .none:     return "secondary"
        case .project:  return "blue"
        case .site:     return "orange"
        case .office:   return "purple"
        case .location: return "green"
        }
    }
}

// MARK: - Worker Sign-off

struct WorkerSignature: Codable, Identifiable {
    var id: UUID = UUID()
    var employeeID: UUID
    var employeeName: String
    var signatureData: Data?
    var signedAt: Date?
    var isSigned: Bool = false
}

// MARK: - Form Submission

struct FormSubmission: BaseModel {
    static func == (lhs: FormSubmission, rhs: FormSubmission) -> Bool { lhs.id == rhs.id }

    var id: UUID = UUID()
    var externalID: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var syncStatus: SyncStatus = .local
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date = Date()

    /// Multi-tenant scope — derived from the parent template's `companyID`
    /// (or `currentCompanyID` as a fallback). Required NOT NULL server-side.
    var companyID: UUID? = nil

    var templateID: UUID
    var templateVersion: Int = 1
    var submittedBy: String
    var submittedAt: Date?
    var responses: [FormFieldResponse] = []
    var isSigned: Bool = false
    var signedAt: Date?
    var signedBy: String?

    // Draft support
    var isDraft: Bool = true

    // Archive support
    var isArchived: Bool = false

    // MARK: Sample data tracking
    // Populated only by SampleDataSeeder; immutable post-insert via DB
    // trigger. Cleared along with the row when an executive runs Clear
    // Sample Data. See SampleData/SampleDataTypes.swift.
    var isSampleData:           Bool      = false
    var sampleDataBatchID:      UUID?     = nil
    var sampleDataSeedVersion:  String?   = nil
    var sampleDataCreatedAt:    Date?     = nil
    var sampleDataCreatedBy:    UUID?     = nil

    // Soft delete
    var isDeleted: Bool    = false
    var deletedAt: Date?   = nil
    var deletedBy: String? = nil

    // MARK: - Linking

    /// What type of entity this form is linked to
    var linkType: FormLinkType = .none

    /// Project link — points to an existing Project record
    var projectID: UUID?

    /// Free-text name for site, office, or custom location
    var linkedName: String?

    /// Physical address for site / location links
    var linkedAddress: String?

    /// GPS coordinates captured at time of submission
    var linkedCoordinate: LocationResponse?

    /// Human-readable display string for the linked entity
    var linkDisplayName: String {
        switch linkType {
        case .none:    return "No link"
        case .project: return linkedName ?? "Project"
        case .site:    return linkedName ?? "Site"
        case .office:  return linkedName ?? "Office"
        case .location:
            if let name = linkedName, !name.isEmpty { return name }
            if let coord = linkedCoordinate {
                return String(format: "%.4f, %.4f", coord.latitude, coord.longitude)
            }
            return "Location"
        }
    }

    // Worker sign-offs (collected for project-linked forms)
    var workerSignatures: [WorkerSignature] = []

    // Locked snapshot reference
    var auditSnapshotID: UUID?

    /// SHA-256 fingerprint of this submission's data, generated at submit time.
    /// Any change to responses after submission will not match this hash.
    var auditHash: String?
}

// MARK: - Sample-data tracking
extension FormSubmission: SampleDataTrackable {}
