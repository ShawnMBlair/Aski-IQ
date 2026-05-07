// CRMModels.swift
// BV APP – CRM Data Models

import Foundation
import SwiftUI

// MARK: - Opportunity Stage

enum OpportunityStage: String, Codable, CaseIterable, Identifiable {
    case newLead          = "New Lead"
    case contacted        = "Contacted"
    case siteVisit        = "Site Visit"
    case estimateRequired = "Estimate"
    case quoteSent        = "Quote Sent"
    case followUp         = "Follow-Up"
    case won              = "Won"
    case lost             = "Lost"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .newLead:          return .gray
        case .contacted:        return .blue
        case .siteVisit:        return .orange
        case .estimateRequired: return .purple
        case .quoteSent:        return .indigo
        case .followUp:         return .yellow
        case .won:              return .green
        case .lost:             return .red
        }
    }

    var icon: String {
        switch self {
        case .newLead:          return "star.fill"
        case .contacted:        return "phone.fill"
        case .siteVisit:        return "mappin.circle.fill"
        case .estimateRequired: return "doc.text.fill"
        case .quoteSent:        return "paperplane.fill"
        case .followUp:         return "arrow.clockwise.circle.fill"
        case .won:              return "checkmark.seal.fill"
        case .lost:             return "xmark.circle.fill"
        }
    }

    var defaultProbability: Int {
        switch self {
        case .newLead: return 10; case .contacted: return 20
        case .siteVisit: return 35; case .estimateRequired: return 50
        case .quoteSent: return 65; case .followUp: return 70
        case .won: return 100; case .lost: return 0
        }
    }

    var nextAction: String {
        switch self {
        case .newLead:          return "Call or schedule a site visit"
        case .contacted:        return "Schedule the site visit"
        case .siteVisit:        return "Create an estimate"
        case .estimateRequired: return "Convert estimate to quote"
        case .quoteSent:        return "Follow up — no response yet"
        case .followUp:         return "Close the deal"
        case .won:              return "Create the project"
        case .lost:             return "Document the loss reason"
        }
    }

    var isActive: Bool { self != .won && self != .lost }

    static var activeStages: [OpportunityStage] {
        allCases.filter { $0.isActive }
    }

    /// Defensive decoder. Handles drifted raw values from before the
    /// 2026-05 stage-normalization migration ('won' / 'new_lead' /
    /// 'follow_up' / 'quote_sent' / 'site_visit') so an in-flight pull
    /// during the rollout doesn't fall back to a default. Also tolerant
    /// of casing variations.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)

        // First try the canonical match.
        if let canonical = OpportunityStage(rawValue: raw) {
            self = canonical
            return
        }

        // Legacy / drifted values from pre-2026-05 SQL that wrote lowercase.
        switch raw {
        case "won":         self = .won
        case "lost":        self = .lost
        case "new_lead":    self = .newLead
        case "follow_up":   self = .followUp
        case "quote_sent":  self = .quoteSent
        case "site_visit":  self = .siteVisit
        case "contacted":   self = .contacted
        case "estimate", "estimateRequired": self = .estimateRequired
        default:            self = .newLead   // safest default for unknown
        }
    }
}

// MARK: - Contact Role

enum ContactRole: String, Codable, CaseIterable, Identifiable {
    case decisionMaker  = "decision_maker"
    case siteContact    = "site_contact"
    case billingContact = "billing_contact"
    case safetyContact  = "safety_contact"
    case general        = "general"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .decisionMaker:  return "Decision Maker"
        case .siteContact:    return "Site Contact"
        case .billingContact: return "Billing Contact"
        case .safetyContact:  return "Safety Contact"
        case .general:        return "General"
        }
    }

    var icon: String {
        switch self {
        case .decisionMaker:  return "person.crop.circle.badge.checkmark"
        case .siteContact:    return "mappin.circle.fill"
        case .billingContact: return "dollarsign.circle.fill"
        case .safetyContact:  return "shield.lefthalf.filled"
        case .general:        return "person.circle"
        }
    }

    var color: Color {
        switch self {
        case .decisionMaker:  return .blue
        case .siteContact:    return .orange
        case .billingContact: return .green
        case .safetyContact:  return .red
        case .general:        return .secondary
        }
    }
}

// MARK: - CRM Contact

struct CRMContact: Identifiable, Codable, Equatable {
    var id:        UUID        = UUID()
    var companyID: UUID?       = nil
    var clientID:  UUID
    var siteID:    UUID?       = nil      // Optional — assigned to a specific site
    var firstName: String      = ""
    var lastName:  String      = ""
    var title:     String      = ""
    var phone:     String      = ""
    var email:     String      = ""
    var role:      ContactRole = .general // Decision Maker, Site Contact, etc.
    var isPrimary: Bool        = false
    var notes:     String      = ""
    var createdAt:  Date        = Date()
    var updatedAt:  Date        = Date()
    var syncStatus: SyncStatus  = .local
    // MARK: Sample data tracking
    // Populated only by SampleDataSeeder; immutable post-insert via DB
    // trigger. Cleared along with the row when an executive runs Clear
    // Sample Data. See SampleData/SampleDataTypes.swift.
    var isSampleData:           Bool      = false
    var sampleDataBatchID:      UUID?     = nil
    var sampleDataSeedVersion:  String?   = nil
    var sampleDataCreatedAt:    Date?     = nil
    var sampleDataCreatedBy:    UUID?     = nil

    var isDeleted:  Bool        = false
    var deletedAt:  Date?       = nil
    var deletedBy:  String?     = nil

    var fullName: String { "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces) }
    var initials: String {
        let f = firstName.first.map(String.init) ?? ""
        let l = lastName.first.map(String.init) ?? ""
        return (f + l).uppercased()
    }
}

// MARK: - CRM Opportunity

struct CRMOpportunity: Identifiable, Codable, Equatable {
    var id:               UUID             = UUID()
    var companyID:        UUID?            = nil
    var clientID:         UUID
    var contactID:        UUID?            = nil
    var title:            String           = ""
    var stage:            OpportunityStage = .newLead
    var value:            Decimal          = 0
    var serviceType:      String           = ""
    var siteAddress:      String           = ""
    var description:      String           = ""
    var estimatedStart:   Date?            = nil
    var estimateID:       UUID?            = nil
    var quoteID:          UUID?            = nil
    var projectID:        UUID?            = nil
    var lossReason:       String           = ""
    var competitorName:   String           = ""
    var probability:      Int              = 10
    var assignedToID:     UUID?            = nil
    var assignedToName:   String           = ""
    var source:           LeadSource       = .directInquiry
    var notes:            String           = ""
    var createdAt:        Date             = Date()
    var updatedAt:        Date             = Date()
    var wonAt:            Date?            = nil
    var lostAt:           Date?            = nil
    var syncStatus:       SyncStatus       = .local
    // MARK: Sample data tracking
    // Populated only by SampleDataSeeder; immutable post-insert via DB
    // trigger. Cleared along with the row when an executive runs Clear
    // Sample Data. See SampleData/SampleDataTypes.swift.
    var isSampleData:           Bool      = false
    var sampleDataBatchID:      UUID?     = nil
    var sampleDataSeedVersion:  String?   = nil
    var sampleDataCreatedAt:    Date?     = nil
    var sampleDataCreatedBy:    UUID?     = nil

    var isDeleted:        Bool             = false
    var deletedAt:        Date?            = nil
    var deletedBy:        String?          = nil

    var weightedValue: Decimal { value * Decimal(probability) / 100 }
    var isActive: Bool { stage.isActive }
    /// The date the opportunity was closed (won or lost). Derived from wonAt/lostAt.
    var closedAt: Date? { wonAt ?? lostAt }
}

enum LeadSource: String, Codable, CaseIterable {
    case directInquiry  = "Direct Inquiry"
    case referral       = "Referral"
    case website        = "Website"
    case coldCall       = "Cold Call"
    case repeat_        = "Repeat Business"
    case tender         = "Tender Board"
    case other          = "Other"
}

// MARK: - CRM Task

enum CRMTaskPriority: String, Codable, CaseIterable {
    case low = "Low"; case normal = "Normal"; case high = "High"; case urgent = "Urgent"

    var color: Color {
        switch self {
        case .low: return .gray; case .normal: return .blue
        case .high: return .orange; case .urgent: return .red
        }
    }
    var icon: String {
        switch self {
        case .low: return "arrow.down"; case .normal: return "minus"
        case .high: return "arrow.up"; case .urgent: return "exclamationmark.2"
        }
    }
}

enum CRMTaskStatus: String, Codable, CaseIterable {
    case open = "Open"; case inProgress = "In Progress"; case done = "Done"
}

struct CRMTask: Identifiable, Codable, Equatable {
    var id:             UUID            = UUID()
    var companyID:      UUID?           = nil
    var title:          String          = ""
    var description_:   String          = ""
    var dueDate:        Date?           = nil
    var priority:       CRMTaskPriority = .normal
    var status:         CRMTaskStatus   = .open
    var assignedToID:   UUID?           = nil
    var assignedToName: String          = ""
    var clientID:       UUID?           = nil
    var contactID:      UUID?           = nil
    var opportunityID:  UUID?           = nil
    var quoteID:        UUID?           = nil
    var projectID:      UUID?           = nil
    var createdAt:      Date            = Date()
    var updatedAt:      Date            = Date()
    var completedAt:    Date?           = nil
    var syncStatus:     SyncStatus      = .local
    // MARK: Sample data tracking
    // Populated only by SampleDataSeeder; immutable post-insert via DB
    // trigger. Cleared along with the row when an executive runs Clear
    // Sample Data. See SampleData/SampleDataTypes.swift.
    var isSampleData:           Bool      = false
    var sampleDataBatchID:      UUID?     = nil
    var sampleDataSeedVersion:  String?   = nil
    var sampleDataCreatedAt:    Date?     = nil
    var sampleDataCreatedBy:    UUID?     = nil

    var isDeleted:      Bool            = false
    var deletedAt:      Date?           = nil
    var deletedBy:      String?         = nil

    var isOverdue: Bool {
        guard let due = dueDate, status != .done else { return false }
        return due < Date()
    }

    var effectiveStatus: CRMTaskStatus {
        status == .done ? .done : status
    }

    var effectiveStatusLabel: String {
        if status == .done { return "Done" }
        if isOverdue { return "Overdue" }
        return status.rawValue
    }

    var effectiveStatusColor: Color {
        if status == .done { return .green }
        if isOverdue { return .red }
        switch status {
        case .open: return .blue
        case .inProgress: return .orange
        case .done: return .green
        }
    }
}

// MARK: - CRM Activity Log

enum CRMActivityType: String, Codable, CaseIterable {
    case leadCreated       = "Lead Created"
    case contactAdded      = "Contact Added"
    case callMade          = "Call Made"
    case emailSent         = "Email Sent"
    case noteAdded         = "Note Added"
    case siteVisit         = "Site Visit"
    case estimateCreated   = "Estimate Created"
    case quoteSent         = "Quote Sent"
    case followUpCompleted = "Follow-Up Completed"
    case stageChanged      = "Stage Changed"
    case quoteWon          = "Quote Won"
    case quoteLost         = "Quote Lost"
    case projectCreated    = "Project Created"
    case taskCreated       = "Task Created"
    case taskCompleted     = "Task Completed"
    case fileUploaded      = "File Uploaded"
    case invoiceCreated      = "Invoice Created"
    case invoiceSent         = "Invoice Sent"
    case paymentReceived     = "Payment Received"
    case invoicePaid         = "Invoice Paid"
    case materialSaleCreated = "Material Sale Created"
    case quoteCreated        = "Quote Created"

    var icon: String {
        switch self {
        case .leadCreated:       return "plus.circle.fill"
        case .contactAdded:      return "person.crop.circle.badge.plus"
        case .callMade:          return "phone.fill"
        case .emailSent:         return "envelope.fill"
        case .noteAdded:         return "note.text"
        case .siteVisit:         return "mappin.circle.fill"
        case .estimateCreated:   return "doc.text.fill"
        case .quoteSent:         return "paperplane.fill"
        case .followUpCompleted: return "checkmark.circle.fill"
        case .stageChanged:      return "arrow.right.circle.fill"
        case .quoteWon:          return "star.circle.fill"
        case .quoteLost:         return "xmark.circle.fill"
        case .projectCreated:    return "folder.badge.plus"
        case .taskCreated:       return "checklist"
        case .taskCompleted:     return "checkmark.circle"
        case .fileUploaded:      return "paperclip"
        case .invoiceCreated:      return "doc.badge.plus"
        case .invoiceSent:         return "envelope.badge.fill"
        case .paymentReceived:     return "creditcard.fill"
        case .invoicePaid:         return "checkmark.seal.fill"
        case .materialSaleCreated: return "shippingbox.fill"
        case .quoteCreated:        return "doc.richtext.fill"
        }
    }

    var color: Color {
        switch self {
        case .leadCreated, .contactAdded: return .blue
        case .callMade:                   return .green
        case .emailSent:                  return .indigo
        case .noteAdded:                  return .secondary
        case .siteVisit:                  return .orange
        case .estimateCreated:            return .purple
        case .quoteSent:                  return .indigo
        case .followUpCompleted:          return .teal
        case .stageChanged:               return .orange
        case .quoteWon, .projectCreated:  return .green
        case .quoteLost:                  return .red
        case .taskCreated, .taskCompleted: return .teal
        case .fileUploaded:               return .gray
        case .invoiceCreated:             return .purple
        case .invoiceSent:                return .indigo
        case .paymentReceived:            return .green
        case .invoicePaid:                return .green
        case .materialSaleCreated:        return .purple
        case .quoteCreated:               return .indigo
        }
    }
}

struct CRMActivity: Identifiable, Codable, Equatable {
    var id:            UUID            = UUID()
    var companyID:     UUID?           = nil
    var type:          CRMActivityType
    var title:         String          = ""
    var notes:         String          = ""
    var date:          Date            = Date()
    var userName:      String          = ""
    var clientID:      UUID?           = nil
    var contactID:     UUID?           = nil
    var opportunityID: UUID?           = nil
    var quoteID:       UUID?           = nil
    var projectID:     UUID?           = nil
    var syncStatus:    SyncStatus      = .local
    // MARK: Sample data tracking
    // Populated only by SampleDataSeeder; immutable post-insert via DB
    // trigger. Cleared along with the row when an executive runs Clear
    // Sample Data. See SampleData/SampleDataTypes.swift.
    var isSampleData:           Bool      = false
    var sampleDataBatchID:      UUID?     = nil
    var sampleDataSeedVersion:  String?   = nil
    var sampleDataCreatedAt:    Date?     = nil
    var sampleDataCreatedBy:    UUID?     = nil

    var isDeleted:     Bool            = false
    var deletedAt:     Date?           = nil
    var deletedBy:     String?         = nil
}

// MARK: - CRM Attachment

enum CRMEntityType: String, Codable {
    case opportunity = "opportunity"
    case contact     = "contact"
    case company     = "company"
}

enum CRMAttachmentFileType: String, Codable {
    case image    = "image"
    case pdf      = "pdf"
    case document = "document"
    case other    = "other"

    var icon: String {
        switch self {
        case .image:    return "photo.fill"
        case .pdf:      return "doc.richtext.fill"
        case .document: return "doc.text.fill"
        case .other:    return "paperclip"
        }
    }

    var color: Color {
        switch self {
        case .image:    return .blue
        case .pdf:      return .red
        case .document: return .indigo
        case .other:    return .gray
        }
    }

    static func from(mimeType: String) -> CRMAttachmentFileType {
        if mimeType.hasPrefix("image/") { return .image }
        if mimeType == "application/pdf" { return .pdf }
        if mimeType.contains("word") || mimeType.contains("document") { return .document }
        return .other
    }

    static func from(extension ext: String) -> CRMAttachmentFileType {
        switch ext.lowercased() {
        case "jpg", "jpeg", "png", "heic", "gif", "webp": return .image
        case "pdf": return .pdf
        case "doc", "docx", "pages": return .document
        default: return .other
        }
    }
}

struct CRMAttachment: Identifiable, Codable, Equatable {
    var id:           UUID                  = UUID()
    var companyID:    UUID?                 = nil
    var entityID:     UUID
    var entityType:   CRMEntityType
    var fileName:     String
    var fileType:     CRMAttachmentFileType
    var fileSize:     Int64                 = 0
    var localPath:    String                // relative to Documents/CRMAttachments/
    var thumbnailData: Data?               // JPEG thumbnail for images
    var createdAt:    Date                  = Date()
    var createdBy:    String               = ""
    var syncStatus:   SyncStatus            = .local
    // MARK: Sample data tracking
    // Populated only by SampleDataSeeder; immutable post-insert via DB
    // trigger. Cleared along with the row when an executive runs Clear
    // Sample Data. See SampleData/SampleDataTypes.swift.
    var isSampleData:           Bool      = false
    var sampleDataBatchID:      UUID?     = nil
    var sampleDataSeedVersion:  String?   = nil
    var sampleDataCreatedAt:    Date?     = nil
    var sampleDataCreatedBy:    UUID?     = nil

    var isDeleted:    Bool                  = false
    var deletedAt:    Date?                 = nil
    var deletedBy:    String?               = nil

    var displaySize: String {
        let kb = Double(fileSize) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }
}

// MARK: - Handoff Checklist Item

struct HandoffChecklistItem: Identifiable, Codable, Equatable {
    var id:            UUID    = UUID()
    var companyID:     UUID?   = nil
    var title:         String
    var isDone:        Bool    = false
    var opportunityID: UUID?
    var projectID:     UUID?
    // MARK: Sample data tracking
    // Populated only by SampleDataSeeder; immutable post-insert via DB
    // trigger. Cleared along with the row when an executive runs Clear
    // Sample Data. See SampleData/SampleDataTypes.swift.
    var isSampleData:           Bool      = false
    var sampleDataBatchID:      UUID?     = nil
    var sampleDataSeedVersion:  String?   = nil
    var sampleDataCreatedAt:    Date?     = nil
    var sampleDataCreatedBy:    UUID?     = nil

    var isDeleted:     Bool    = false
    var deletedAt:     Date?   = nil
    var deletedBy:     String? = nil
}

extension HandoffChecklistItem {
    static func defaultChecklist(opportunityID: UUID, projectID: UUID?) -> [HandoffChecklistItem] {
        let items = [
            "Confirm final scope", "Confirm client contact", "Confirm site address",
            "Confirm schedule", "Confirm crew requirements", "Confirm materials",
            "Confirm equipment", "Confirm safety requirements", "Confirm forms required",
            "Confirm billing terms", "Create project folder", "Create schedule placeholder"
        ]
        return items.map {
            HandoffChecklistItem(title: $0, opportunityID: opportunityID, projectID: projectID)
        }
    }
}

// MARK: - Sample-data tracking
extension CRMContact: SampleDataTrackable {}

// MARK: - Sample-data tracking
extension CRMOpportunity: SampleDataTrackable {}

// MARK: - Sample-data tracking
extension CRMTask: SampleDataTrackable {}

// MARK: - Sample-data tracking
extension CRMActivity: SampleDataTrackable {}

// MARK: - Sample-data tracking
extension CRMAttachment: SampleDataTrackable {}

// MARK: - Sample-data tracking
extension HandoffChecklistItem: SampleDataTrackable {}
