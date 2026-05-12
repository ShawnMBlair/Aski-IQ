// ExpenseAttachment.swift
// Aski IQ — Expenses v1: photo/PDF receipt attachment model
//
// Mirrors CRMAttachment + Certificate attachment patterns. Lives
// as a separate row (not embedded in Expense) so:
//   - One expense can have multiple receipts (front/back, multi-page)
//   - Attachments can be added after the expense exists (Office Staff
//     uploading receipts in batch and assigning later)
//   - File data syncs independently from the expense metadata
//
// File data is stored as Data on the row in v1 — matches the
// existing CRM attachment + certificate file storage pattern. If
// payload size becomes a problem we move to Supabase Storage with
// a URL reference, mirroring the DJR PDF migration path.

import Foundation

// MARK: - Capture method

enum ExpenseAttachmentSource: String, Codable, CaseIterable {
    case camera     = "camera"
    case library    = "library"
    case filePicker = "file_picker"
    case email      = "email"        // forwarded receipt — future use
    case ocrScan    = "ocr_scan"     // v2 — placeholder

    var displayName: String {
        switch self {
        case .camera:     return "Camera"
        case .library:    return "Photo Library"
        case .filePicker: return "Files"
        case .email:      return "Email"
        case .ocrScan:    return "Scanned"
        }
    }
}

// MARK: - File type

enum ExpenseAttachmentFileType: String, Codable, CaseIterable {
    case image  = "image"   // JPG / PNG / HEIC
    case pdf    = "pdf"
    case other  = "other"

    var icon: String {
        switch self {
        case .image: return "photo.fill"
        case .pdf:   return "doc.fill"
        case .other: return "doc"
        }
    }

    static func from(filename: String) -> ExpenseAttachmentFileType {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "heif": return .image
        case "pdf":                                 return .pdf
        default:                                    return .other
        }
    }
}

// MARK: - Attachment

struct ExpenseAttachment: BaseModel {

    // MARK: BaseModel boilerplate
    var id: UUID = UUID()
    var externalID: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var syncStatus: SyncStatus = .local
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date = Date()

    // MARK: Tenant scope
    var companyID: UUID? = nil

    // MARK: Parent linkage
    var expenseID: UUID

    // MARK: File metadata
    var fileName: String = ""
    var fileType: ExpenseAttachmentFileType = .image
    var fileSizeBytes: Int = 0
    var mimeType: String = ""

    // MARK: File data
    /// Inline binary. Base64-encoded for the Supabase payload (matches
    /// existing CRM / certificate attachment pattern). Stripped from
    /// the BaseModel codable surface by SyncEngineExpenses if too large
    /// to push in one go — the engine chunks via Supabase Storage in
    /// that case (deferred to v1.1 if size becomes an issue).
    var fileData: Data? = nil
    /// Square thumbnail (200x200) for grid display. Skipped for PDFs.
    var thumbnailData: Data? = nil

    // MARK: Capture provenance
    var source: ExpenseAttachmentSource = .camera

    /// Designates THE primary receipt for the expense. When false,
    /// this is a supplementary doc (back-of-receipt, addendum, etc.).
    /// `Expense.isMissingReceipt(attachments:)` requires at least one
    /// primary attachment.
    var isPrimaryReceipt: Bool = true

    // MARK: Soft delete
    var isDeleted: Bool = false
    var deletedAt: Date? = nil
    var deletedBy: String? = nil
}

// MARK: - Display helpers

extension ExpenseAttachment {
    var displaySize: String {
        let bytes = Double(fileSizeBytes)
        if bytes < 1_024 { return "\(fileSizeBytes) B" }
        if bytes < 1_024 * 1_024 { return String(format: "%.0f KB", bytes / 1_024) }
        return String(format: "%.1f MB", bytes / (1_024 * 1_024))
    }
}
