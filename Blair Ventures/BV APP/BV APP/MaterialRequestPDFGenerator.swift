// MaterialRequestPDFGenerator.swift
// Aski IQ — On-approval PDF generation for Material Requests.
//
// FLOW
//   1. AppStore.approveMaterialRequest flips status → .approved and calls
//      this generator.
//   2. Renders PDF via MaterialRequestPDFRenderer using the resolved
//      destination name (project / material sale) and approver.
//   3. Writes the file to the app's Documents directory as
//      <UUID>.pdf (originalFileName = MR_<requestNumber>.pdf).
//   4. Registers a ProjectDocument under the right owner based on
//      destinationType:
//        • .project      → store.addDocument        (project doc grid)
//        • .materialSale → store.addMaterialSaleDoc (sale doc grid)
//        • .internalUse  → file is written but no ProjectDocument
//                          registered (no grid to surface it in)
//   5. Stamps pdfStoragePath + pdfGeneratedAt on the MR row so the audit
//      trail shows when the doc was produced. Pushed back to Supabase by
//      the next pushPendingMaterialRequests() cycle.
//
// IDEMPOTENCY
//   On re-approval (e.g. status was changed back to draft and re-approved),
//   the prior auto-generated doc with matching originalFileName is removed
//   from the destination grid before the new one is registered. The disk
//   file is also deleted via the doc-store's delete handler.
//
// NO-OP CONDITIONS
//   • iOS-only — wrapped in #if canImport(UIKit). On macOS this whole module
//     is excluded so the renderer (also UIKit) never gets referenced.
//   • Aborts silently if the MR has no line items — generating a blank
//     approval doc would only confuse the audit trail.

#if canImport(UIKit)
import Foundation
import UIKit

@MainActor
final class MaterialRequestPDFGenerator {

    static let shared = MaterialRequestPDFGenerator()
    private init() {}

    /// File-naming marker used to find the prior auto-generated PDF when
    /// re-approving. Mirrors the SignedQuotePDFGenerator `_signed.pdf`
    /// convention so future copy-to-X helpers can find these the same way.
    private static let originalFilenamePrefix = "MR_"
    private static let originalFilenameSuffix = ".pdf"

    /// Render + persist + register. Updates the passed MR via the store so
    /// the caller doesn't have to round-trip through updateMaterialRequest.
    func generateAndAttach(for mr: MaterialRequest, store: AppStore) {
        guard !mr.lineItems.isEmpty else {
            print("ℹ️ MaterialRequestPDFGenerator: skipping \(mr.requestNumber) — no line items")
            return
        }

        let destinationName = resolveDestinationName(for: mr, store: store)
        let supplierName    = mr.supplierID.flatMap { sid in
            store.suppliers.first { $0.id == sid }?.name
        }
        let approver = mr.approvedByName.isEmpty
            ? store.currentUser?.fullName
            : mr.approvedByName

        let pdfData = MaterialRequestPDFRenderer(
            mr:              mr,
            destinationName: destinationName,
            supplierName:    supplierName,
            approvedBy:      approver
        ).render()

        let safeNumber = mr.requestNumber
            .components(separatedBy: .whitespacesAndNewlines).joined(separator: "_")
        let originalFilename = "\(Self.originalFilenamePrefix)\(safeNumber)\(Self.originalFilenameSuffix)"
        let storedFileName = "\(UUID().uuidString).pdf"
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docDir.appendingPathComponent(storedFileName)

        do {
            try pdfData.write(to: url)
        } catch {
            ToastService.shared.error("Couldn't save MR PDF: \(error.localizedDescription)")
            return
        }

        // Register against the correct owner based on destination_type.
        // Internal-use requests don't get a grid entry — there's nowhere to
        // show it — but the file still lives on disk for share-sheet use.
        register(
            originalFilename: originalFilename,
            storedFileName:   storedFileName,
            fileSize:         pdfData.count,
            for:              mr,
            store:            store
        )

        // Stamp the MR so the audit trail and any "Open PDF" button can
        // resolve the file. updateMaterialRequest pushes it through the
        // sync layer; the DB trigger captures the new pdf_storage_path in
        // the audit metadata.
        var updated = mr
        updated.pdfStoragePath = storedFileName
        updated.pdfGeneratedAt = Date()
        updated.updatedAt      = Date()
        updated.syncStatus     = .pending
        if let i = store.materialRequests.firstIndex(where: { $0.id == mr.id }) {
            store.materialRequests[i] = updated
        }
        Task { await SyncEngine.shared.pushPendingMaterialRequests() }
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
