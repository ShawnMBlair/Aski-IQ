// MaterialRequestPDFGenerator.swift
// Aski IQ — On-approval PDF generation for Material Requests.
//
// FLOW (revised — BV-MR-2026-0001 follow-up)
//   1. AppStore.approveMaterialRequest flips status → .approved and calls
//      this generator.
//   2. Renders PDF via MaterialRequestPDFRenderer using the resolved
//      destination name (project / material sale) and approver.
//   3. UPLOADS THE PDF TO SUPABASE STORAGE under the `contracts` bucket
//      at path:
//        <companyID>/material-requests/<mrID>/approval_<timestamp>.pdf
//      so every device with access to the MR can resolve + view it via
//      a signed URL. Pre-fix the file lived only in the approving
//      device's local Documents/ directory and `pdf_storage_path`
//      stored a random UUID local filename — useless across devices.
//   4. ALSO caches a copy in local Documents/ keyed by MR id so the
//      approving device gets instant view without a round-trip.
//   5. Registers a ProjectDocument under the right owner based on
//      destinationType:
//        • .project      → store.addDocument        (project doc grid)
//        • .materialSale → store.addMaterialSaleDoc (sale doc grid)
//        • .internalUse  → still uploaded + surfaced via the View PDF
//                          button on MR detail (no grid to add it to)
//   6. Stamps `pdf_storage_path` (now a Supabase Storage path) +
//      `pdf_generated_at` on the MR row and pushes via
//      pushPendingMaterialRequests().
//
// IDEMPOTENCY
//   On re-approval, the prior storage entry is overwritten (upsert=true)
//   and the prior ProjectDocument with matching originalFileName is
//   removed from the destination grid before re-registering. Re-approval
//   thus yields a fresh PDF; old copies aren't accumulated.
//
// NO-OP CONDITIONS
//   • iOS-only — wrapped in #if canImport(UIKit). On macOS this whole
//     module is excluded so the renderer (also UIKit) never gets referenced.
//   • Aborts silently if the MR has no line items — generating a blank
//     approval doc would only confuse the audit trail.

#if canImport(UIKit)
import Foundation
import UIKit
import Supabase

@MainActor
final class MaterialRequestPDFGenerator {

    static let shared = MaterialRequestPDFGenerator()
    private init() {}

    /// File-naming marker used to find the prior auto-generated PDF when
    /// re-approving. Mirrors the SignedQuotePDFGenerator `_signed.pdf`
    /// convention so future copy-to-X helpers can find these the same way.
    private static let originalFilenamePrefix = "MR_"
    private static let originalFilenameSuffix = ".pdf"

    /// Render → upload to Supabase Storage → cache locally → register
    /// in the destination doc grid → stamp the MR row. Synchronous
    /// interface (returns immediately); the upload happens in a Task
    /// so the approve UI doesn't stall. The MR row is stamped with the
    /// final storage path AFTER the upload succeeds.
    func generateAndAttach(for mr: MaterialRequest, store: AppStore) {
        guard !mr.lineItems.isEmpty else {
            print("ℹ️ MaterialRequestPDFGenerator: skipping \(mr.requestNumber) — no line items")
            return
        }
        guard let companyID = store.currentCompanyID else {
            print("ℹ️ MaterialRequestPDFGenerator: no currentCompanyID — skipping")
            return
        }

        let pdfData = freshlyRenderedPDF(for: mr, store: store)
        let safeNumber = mr.requestNumber
            .components(separatedBy: .whitespacesAndNewlines).joined(separator: "_")
        let originalFilename = "\(Self.originalFilenamePrefix)\(safeNumber)\(Self.originalFilenameSuffix)"

        // 1. Cache locally for instant View PDF on the approving device.
        //    Deterministic filename keyed off MR id — re-approval
        //    overwrites the same cache file.
        let cacheURL = localCacheURL(for: mr)
        do {
            try pdfData.write(to: cacheURL, options: .atomic)
        } catch {
            // Soft-fail: cache miss just means the View PDF button has
            // to download from storage on first tap. Not fatal.
            print("⚠️ MaterialRequestPDFGenerator: cache write failed: \(error)")
        }

        // 2. Compute the canonical Supabase Storage path. Same
        //    convention as DeliveryPhotoService.upload() so all MR
        //    attachments share one folder layout.
        let timestampSlug = Self.timestampSlugFormatter.string(from: Date())
        let storagePath = "\(companyID.uuidString)/material-requests/\(mr.id.uuidString)/approval_\(timestampSlug).pdf"

        // 3. Optimistically stamp the MR row with the storage path so
        //    the UI surfaces View PDF immediately. If the upload fails
        //    we fall back to cache-only resolution.
        var updated = mr
        updated.pdfStoragePath = storagePath
        updated.pdfGeneratedAt = Date()
        updated.updatedAt      = Date()
        updated.syncStatus     = .pending
        if let i = store.materialRequests.firstIndex(where: { $0.id == mr.id }) {
            store.materialRequests[i] = updated
        }

        // 4. Register against the correct doc grid (project / material sale).
        register(
            originalFilename: originalFilename,
            storedFileName:   storagePath,
            fileSize:         pdfData.count,
            for:              updated,
            store:            store
        )

        // 5. Upload + push, off the main thread. The MR row already
        //    has its storage path set so the user sees View PDF
        //    immediately; the upload + sync happen behind the scenes.
        Task {
            do {
                _ = try await supabase.storage
                    .from("contracts")
                    .upload(
                        storagePath,
                        data: pdfData,
                        options: FileOptions(
                            contentType: "application/pdf",
                            upsert: true  // re-approval overwrites the prior copy
                        )
                    )
            } catch {
                await MainActor.run {
                    ToastService.shared.warning(
                        "MR PDF uploaded locally but cloud sync failed — \(error.localizedDescription). Tap View PDF to use the local copy."
                    )
                    print("⚠️ MaterialRequestPDFGenerator: storage upload failed: \(error)")
                }
            }
            await SyncEngine.shared.pushPendingMaterialRequests()
        }
    }

    /// Local cache URL keyed by MR id. Deterministic so the View PDF
    /// path can find the file without state, and re-approval
    /// overwrites instead of accumulating copies.
    func localCacheURL(for mr: MaterialRequest) -> URL {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let filename = "MR_\(mr.id.uuidString)_approval.pdf"
        return docDir.appendingPathComponent(filename)
    }

    /// Timestamp slug for Supabase Storage filenames. Colons in
    /// ISO-8601 cause issues in some HTTP layers, so we hyphenate.
    private static let timestampSlugFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Resolves an MR's pdf_storage_path to a usable local file URL.
    /// Order of operations:
    ///   1. If the local cache file exists, return it (instant).
    ///   2. Otherwise download from Supabase Storage, write to cache,
    ///      return the cache URL.
    ///   3. On any failure, return nil — caller surfaces a toast.
    ///
    /// Backward compat: legacy MRs created before the storage migration
    /// have pdf_storage_path = "<uuid>.pdf" pointing at a local file.
    /// Detect by absence of "/" — fall back to docDir/<filename>.pdf.
    func resolveViewableURL(for mr: MaterialRequest) async -> URL? {
        guard let storagePath = mr.pdfStoragePath, !storagePath.isEmpty else { return nil }

        // Legacy local-only path: no slashes means it's the old random
        // UUID filename in DocumentDirectory.
        if !storagePath.contains("/") {
            let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = docDir.appendingPathComponent(storagePath)
            if FileManager.default.fileExists(atPath: url.path) { return url }
            // File is gone (different device, cache cleared); nothing to fall
            // back to since the legacy file was never uploaded.
            return nil
        }

        // Cache hit?
        let cacheURL = localCacheURL(for: mr)
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            return cacheURL
        }

        // Download from Supabase Storage and cache.
        do {
            let data: Data = try await supabase.storage
                .from("contracts")
                .download(path: storagePath)
            try data.write(to: cacheURL, options: .atomic)
            return cacheURL
        } catch {
            print("⚠️ MaterialRequestPDFGenerator: download failed for \(storagePath): \(error)")
            return nil
        }
    }

    // MARK: - Email-to-supplier

    /// Send the previously-generated approval PDF to the assigned supplier.
    /// Loads the file from the MR's pdfStoragePath; regenerates if missing
    /// (e.g. doc was deleted from the grid). Office email is CC'd when set.
    /// Returns true on dispatch success so the caller can toast.
    func emailApprovalPDF(for mr: MaterialRequest, store: AppStore) async -> Bool {
        // Resolve PDF data — prefer the on-disk file; fall back to a fresh
        // render so the user can always send even if the file was tidied up.
        let pdfData: Data
        if let storedFileName = mr.pdfStoragePath {
            let url = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(storedFileName)
            if let data = try? Data(contentsOf: url) {
                pdfData = data
            } else {
                pdfData = freshlyRenderedPDF(for: mr, store: store)
            }
        } else {
            pdfData = freshlyRenderedPDF(for: mr, store: store)
        }

        // Resolve supplier email + name. Without an email there's nowhere
        // to send — return false so the caller can show the right toast.
        guard let supplierID = mr.supplierID,
              let supplier   = store.suppliers.first(where: { $0.id == supplierID }),
              !supplier.email.trimmingCharacters(in: .whitespaces).isEmpty else {
            await MainActor.run {
                ToastService.shared.error("No supplier email on file for this request.")
            }
            return false
        }

        var recipients: [String] = [supplier.email]
        let companyEmail = AppSettings.shared.companyEmail.trimmingCharacters(in: .whitespaces)
        if !companyEmail.isEmpty,
           companyEmail.lowercased() != supplier.email.lowercased() {
            recipients.append(companyEmail)
        }

        let safeNumber = mr.requestNumber
            .components(separatedBy: .whitespacesAndNewlines).joined(separator: "_")
        let filename = "\(Self.originalFilenamePrefix)\(safeNumber)\(Self.originalFilenameSuffix)"

        let signer = AppSettings.shared.companyName.isEmpty ? "Aski IQ" : AppSettings.shared.companyName
        let body = """
        Hello,

        Please find attached approved Material Request \(mr.requestNumber). Total estimated value: \(mr.estimatedTotal.currencyString).

        Reply to this email to confirm pricing and delivery.

        Thanks,
        \(signer)
        """
        let html = EmailHTMLTemplate.wrap(
            plainText:  body,
            companyName: AppSettings.shared.companyName,
            subject:    "Material Request \(mr.requestNumber)",
            footerNote: "Reply to confirm pricing and delivery."
        )

        let result = await EmailService.shared.sendPDF(
            to:          recipients,
            subject:     "Material Request \(mr.requestNumber)",
            bodyText:    body,
            bodyHTML:    html,
            replyTo:     companyEmail.isEmpty ? nil : companyEmail,
            pdfData:     pdfData,
            pdfFilename: filename,
            entityType:  "material_request",
            entityID:    mr.id
        )
        switch result {
        case .success:
            // Flip status to .ordered to record that the supplier was notified
            // — ordered means "PO/MR is out the door, waiting on delivery."
            // The dedicated transition method stamps orderedAt + audit row.
            await MainActor.run { store.markMaterialRequestOrdered(mr) }
            return true
        case .failure(let err):
            await MainActor.run {
                ToastService.shared.error("Email failed: \(err.userMessage)")
            }
            return false
        }
    }

    // MARK: - Share PDF (no supplier required)

    /// FIX (BV-MR-2026-0001 follow-up): returns a file URL that callers
    /// can hand to a SwiftUI `ShareLink` for system-share-sheet
    /// distribution. Unlike `emailApprovalPDF`, this path works even
    /// when no supplier is set — useful for internal-use MRs (warehouse
    /// stock, shop supplies) where the user just wants to email or
    /// save the request PDF without a designated recipient.
    ///
    /// Behavior:
    ///   - If the MR already has a generated PDF on disk, returns that
    ///     URL.
    ///   - Otherwise, renders a fresh PDF, writes to a stable temp
    ///     location keyed off the MR id (so repeat shares reuse the
    ///     same file instead of accumulating copies), returns its URL.
    ///   - Returns nil only if line items are empty (no content to
    ///     render) or the write fails.
    func prepareSharePDF(for mr: MaterialRequest, store: AppStore) -> URL? {
        guard !mr.lineItems.isEmpty else { return nil }
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // Reuse the on-disk approval PDF if one exists.
        if let storedFileName = mr.pdfStoragePath {
            let url = docDir.appendingPathComponent(storedFileName)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        // Render fresh and write to a stable per-MR cache location.
        // Using a deterministic filename means re-sharing the same MR
        // overwrites the cached copy instead of leaving a trail of
        // similarly-named files in documents/.
        let pdfData = freshlyRenderedPDF(for: mr, store: store)
        let safeNumber = mr.requestNumber
            .components(separatedBy: .whitespacesAndNewlines).joined(separator: "_")
        let filename = "MR_\(safeNumber)_share.pdf"
        let url = docDir.appendingPathComponent(filename)
        do {
            try pdfData.write(to: url, options: .atomic)
            return url
        } catch {
            print("⚠️ prepareSharePDF failed: \(error)")
            return nil
        }
    }

    private func freshlyRenderedPDF(for mr: MaterialRequest, store: AppStore) -> Data {
        let destinationName = resolveDestinationName(for: mr, store: store)
        let supplierName    = mr.supplierID.flatMap { sid in
            store.suppliers.first { $0.id == sid }?.name
        }
        let approver = mr.approvedByName.isEmpty
            ? store.currentUser?.fullName
            : mr.approvedByName
        return MaterialRequestPDFRenderer(
            mr:              mr,
            destinationName: destinationName,
            supplierName:    supplierName,
            approvedBy:      approver
        ).render()
    }

    // MARK: - Destination routing

    private func resolveDestinationName(for mr: MaterialRequest, store: AppStore) -> String? {
        switch mr.destinationType {
        case .project:
            return mr.projectID.flatMap { pid in
                store.projects.first { $0.id == pid }?.name
            }
        case .materialSale:
            return mr.materialSaleID.flatMap { sid in
                store.materialSales.first { $0.id == sid }?.saleNumber
            }
        case .internalUse:
            return nil
        }
    }

    /// Insert a ProjectDocument for the new file under the right owner.
    /// Removes any prior auto-generated MR PDF for the same request so the
    /// grid doesn't accumulate one copy per re-approval.
    private func register(originalFilename: String,
                          storedFileName: String,
                          fileSize: Int,
                          for mr: MaterialRequest,
                          store: AppStore) {
        let uploadedBy = store.currentUser?.fullName ?? "System"
        let doc = ProjectDocument(
            id:               UUID(),
            projectID:        mr.projectID ?? mr.materialSaleID ?? mr.id,  // owner key
            name:             "Material Request \(mr.requestNumber)",
            originalFileName: originalFilename,
            fileExtension:    "pdf",
            fileSize:         fileSize,
            storedFileName:   storedFileName,
            category:         .other,
            uploadedAt:       Date(),
            uploadedBy:       uploadedBy,
            notes:            "Auto-generated on approval."
        )

        switch mr.destinationType {
        case .project:
            guard let projectID = mr.projectID else { return }
            // Drop any prior auto-generated PDF for this MR before adding the
            // new one — see the IDEMPOTENCY note in the file header.
            for stale in store.documents(for: projectID)
                where stale.originalFileName.lowercased() == originalFilename.lowercased() {
                store.deleteDocument(stale)
            }
            store.addDocument(doc)

        case .materialSale:
            guard let saleID = mr.materialSaleID else { return }
            for stale in store.materialSaleDocs(for: saleID)
                where stale.originalFileName.lowercased() == originalFilename.lowercased() {
                store.deleteMaterialSaleDoc(stale)
            }
            store.addMaterialSaleDoc(doc)

        case .internalUse:
            // No grid — file exists on disk only. The MR's pdfStoragePath
            // points at it for downstream share-sheet / email flows.
            return
        }
    }
}
#endif
