// ContractDocumentService.swift
// Aski IQ — Upload contract PDFs to Supabase Storage + extract text
// for AI review.
//
// WHY THIS EXISTS
// Phase 1 AI review needed copy-paste of contract text. Useless for a
// 40-page MSA. This service:
//   1. Uploads a chosen PDF/DOCX to the `contracts` bucket under the
//      company-scoped path `<companyID>/contracts/<contractID>/<filename>`.
//   2. Extracts text via PDFKit (PDFs only) so the AI Review Sheet can
//      pre-populate the text editor — no copy-paste required.
//   3. Stores the storage path on the contract row + serves signed
//      URLs for download.
//
// PATH CONVENTION (matches the storage RLS policies in the migration)
//   <companyID>/contracts/<contractID>/<filename>.pdf       — primary contract
//   <companyID>/compliance/<documentID>.<ext>               — insurance / bonds
//
// SUPABASE STORAGE
// The bucket is private (public:false). Reads happen via signed URLs
// (default 1-hour validity). The Storage RLS we deployed in this
// migration uses `storage.foldername(name)[1]::uuid` to scope by
// company — so the path's first segment MUST be the company UUID or
// the upload is rejected.

import Foundation
import PDFKit
import Supabase

@MainActor
final class ContractDocumentService {

    static let shared = ContractDocumentService()
    private init() {}

    enum DocumentError: Error, LocalizedError {
        case noCompany
        case fileNotReadable
        case fileTooLarge(Int)
        case uploadFailed(Error)
        case textExtractionFailed
        case signedURLFailed(Error)

        var errorDescription: String? {
            switch self {
            case .noCompany:                return "Sign in before uploading."
            case .fileNotReadable:          return "Couldn't read the selected file."
            case .fileTooLarge(let mb):     return "File is \(mb)MB — limit is 25MB. Compress the PDF and try again."
            case .uploadFailed(let e):      return "Upload failed: \(e.localizedDescription)"
            case .textExtractionFailed:    return "Couldn't extract text from this PDF — it may be a scan. AI review needs OCR or text-based PDFs."
            case .signedURLFailed(let e):  return "Couldn't generate download link: \(e.localizedDescription)"
            }
        }
    }

    /// Result of a successful upload — stash on the parent record.
    struct UploadResult {
        let storagePath: String           // <companyID>/contracts/<contractID>/<filename>
        let filename:    String
        let extractedText: String?         // nil for non-PDF or scan-only PDFs
        let pageCount:    Int?
    }

    /// Hard limit. Aligns with Supabase's default 50MB per object cap;
    /// 25MB is the largest a sane construction contract gets.
    private let maxBytes = 25 * 1024 * 1024

    // MARK: - Upload (contract primary PDF)

    /// Uploads `data` to the `contracts` bucket under the company-scoped
    /// path. Extracts text on the way through if it's a PDF.
    /// Returns the path so the caller can persist it on the contract.
    func upload(
        data: Data,
        filename: String,
        contractID: UUID,
        in store: AppStore
    ) async throws -> UploadResult {
        guard let companyID = store.currentCompanyID else {
            throw DocumentError.noCompany
        }
        guard data.count <= maxBytes else {
            throw DocumentError.fileTooLarge(data.count / (1024 * 1024))
        }

        let safeName = sanitizeFilename(filename)
        let path = "\(companyID.uuidString)/contracts/\(contractID.uuidString)/\(safeName)"
        let mime = mimeType(for: safeName)

        do {
            _ = try await supabase.storage
                .from("contracts")
                .upload(
                    path,
                    data: data,
                    options: FileOptions(
                        contentType: mime,
                        upsert: true                      // overwrite when re-uploading
                    )
                )
        } catch {
            throw DocumentError.uploadFailed(error)
        }

        // Extract text best-effort for AI review. Only PDFs are supported
        // in V1 — DOCX would need a server-side parser or a Deno
        // function, neither of which we want to build now.
        var extracted: String? = nil
        var pageCount: Int? = nil
        if mime == "application/pdf",
           let pdf = PDFDocument(data: data) {
            pageCount = pdf.pageCount
            extracted = (0..<pdf.pageCount)
                .compactMap { pdf.page(at: $0)?.string }
                .joined(separator: "\n\n")
            if extracted?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                extracted = nil   // probably a scan — caller can show "OCR needed"
            }
        }

        return UploadResult(
            storagePath:   path,
            filename:      safeName,
            extractedText: extracted,
            pageCount:     pageCount
        )
    }

    /// Same upload mechanics, scoped to compliance documents (insurance
    /// certs, bonds). Path: <companyID>/compliance/<docID>.<ext>.
    func uploadComplianceDocument(
        data: Data,
        filename: String,
        documentID: UUID,
        in store: AppStore
    ) async throws -> UploadResult {
        guard let companyID = store.currentCompanyID else {
            throw DocumentError.noCompany
        }
        guard data.count <= maxBytes else {
            throw DocumentError.fileTooLarge(data.count / (1024 * 1024))
        }

        let safeName = sanitizeFilename(filename)
        let ext = (safeName as NSString).pathExtension.isEmpty ? "pdf" : (safeName as NSString).pathExtension
        let path = "\(companyID.uuidString)/compliance/\(documentID.uuidString).\(ext)"

        do {
            _ = try await supabase.storage
                .from("contracts")
                .upload(
                    path,
                    data: data,
                    options: FileOptions(
                        contentType: mimeType(for: safeName),
                        upsert: true
                    )
                )
        } catch {
            throw DocumentError.uploadFailed(error)
        }

        return UploadResult(
            storagePath:   path,
            filename:      safeName,
            extractedText: nil,
            pageCount:     nil
        )
    }

    // MARK: - Signed download URL

    /// Returns a short-lived signed URL for fetching the file. Default
    /// 1-hour validity matches Supabase's recommended default for
    /// preview/share use cases.
    func signedURL(for storagePath: String, validitySeconds: Int = 3600) async throws -> URL {
        do {
            return try await supabase.storage
                .from("contracts")
                .createSignedURL(path: storagePath, expiresIn: validitySeconds)
        } catch {
            throw DocumentError.signedURLFailed(error)
        }
    }

    // MARK: - Fetch + extract text from an already-uploaded document

    /// Downloads a previously-uploaded document from the contracts
    /// bucket and extracts its text via PDFKit. Returns the extracted
    /// text + page count + filename.
    ///
    /// USE CASE
    /// Lets the AI Review and AI Diff sheets load text from a contract's
    /// already-attached primary document, instead of requiring the user
    /// to re-upload or copy-paste. Pull-from-storage means the text is
    /// available even if the user closed and reopened the contract.
    ///
    /// PDF-ONLY in V1
    /// PDFKit reads PDFs natively. DOCX would need a server-side
    /// extractor (Deno function with mammoth or similar) — not in scope
    /// for this round. Non-PDF storage paths surface as
    /// `.textExtractionFailed`.
    func fetchAndExtractText(storagePath: String) async throws -> UploadResult {
        let data: Data
        do {
            data = try await supabase.storage
                .from("contracts")
                .download(path: storagePath)
        } catch {
            throw DocumentError.uploadFailed(error)
        }

        // Best-effort filename from the storage path's last component.
        let filename = (storagePath as NSString).lastPathComponent

        let lower = filename.lowercased()
        guard lower.hasSuffix(".pdf") else {
            // Non-PDF — return the result with nil text. Callers see
            // `extractedText == nil` and surface "couldn't auto-extract".
            return UploadResult(
                storagePath:   storagePath,
                filename:      filename,
                extractedText: nil,
                pageCount:     nil
            )
        }

        guard let pdf = PDFDocument(data: data) else {
            throw DocumentError.textExtractionFailed
        }
        let pageCount = pdf.pageCount
        var text = (0..<pageCount)
            .compactMap { pdf.page(at: $0)?.string }
            .joined(separator: "\n\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Probably a scanned PDF with no embedded text.
            text = ""
        }
        return UploadResult(
            storagePath:   storagePath,
            filename:      filename,
            extractedText: text.isEmpty ? nil : text,
            pageCount:     pageCount
        )
    }

    // MARK: - Helpers

    /// Replace characters that break URL routing or RLS path parsing.
    /// Storage rejects names with `/` or excessive control characters.
    private func sanitizeFilename(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?\"<>|"))
            .joined(separator: "_")
        return cleaned.isEmpty ? "contract.pdf" : cleaned
    }

    private func mimeType(for filename: String) -> String {
        let lower = filename.lowercased()
        if lower.hasSuffix(".pdf")  { return "application/pdf" }
        if lower.hasSuffix(".docx") { return "application/vnd.openxmlformats-officedocument.wordprocessingml.document" }
        if lower.hasSuffix(".doc")  { return "application/msword" }
        if lower.hasSuffix(".jpg")  { return "image/jpeg" }
        if lower.hasSuffix(".jpeg") { return "image/jpeg" }
        if lower.hasSuffix(".png")  { return "image/png" }
        return "application/octet-stream"
    }
}
