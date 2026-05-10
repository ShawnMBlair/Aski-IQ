// PurchaseOrderPDFGenerator.swift
// Aski IQ — On-demand PDF + supplier email dispatch for Purchase Orders.
//
// FLOW
//   User taps "Send to Supplier" on a draft PO → this generator renders
//   the PO PDF, optionally registers it as a ProjectDocument under the
//   linked project, and emails it to the supplier (with company email
//   CC'd). On dispatch success the caller flips status .draft → .sent
//   via AppStore.markPurchaseOrderSent.
//
// CONTRAST WITH MaterialRequestPDFGenerator
//   MR generator runs automatically on approval and persists pdfStoragePath
//   on the row. PO generator is on-demand only and doesn't add new DB
//   columns — the email + the project-doc-grid copy are the canonical
//   artifacts. Keeps the migration surface minimal while still giving the
//   manager a one-tap "send it" action.
//
// FAILURE BEHAVIOR
//   • No supplier email on file → false + toast asking the user to set one.
//   • Email send error → false + toast with the user-facing error.
//   • Success → caller marks PO as sent + toasts.

#if canImport(UIKit)
import Foundation
import UIKit

@MainActor
final class PurchaseOrderPDFGenerator {

    static let shared = PurchaseOrderPDFGenerator()
    private init() {}

    /// Render the PO PDF and email it to the supplier. Returns true on
    /// successful dispatch so the caller can flip status + toast.
    func emailToSupplier(po: PurchaseOrder, store: AppStore) async -> Bool {
        // Resolve supplier + email up-front. Without an address there's
        // nowhere to send.
        guard let supplierID = po.supplierID,
              let supplier   = store.suppliers.first(where: { $0.id == supplierID }) else {
            ToastService.shared.error("No supplier set on this PO.")
            return false
        }
        let supplierEmail = supplier.email.trimmingCharacters(in: .whitespaces)
        guard !supplierEmail.isEmpty else {
            ToastService.shared.error("Supplier has no email on file. Add one to \(supplier.name) and try again.")
            return false
        }

        // Render the PDF (off-main is fine — UIKit drawing is allowed
        // off-main in modern iOS for graphics contexts created within the
        // task, and this matches the existing InvoicePDFRenderer pattern).
        let projectName = po.projectID.flatMap { pid in
            store.projects.first { $0.id == pid }?.name
        }
        let pdfData = PurchaseOrderPDFRenderer(po: po, projectName: projectName).render()

        // Register the PDF on the project's doc grid so anyone with
        // project access can re-download it later. Skipped when the PO
        // isn't linked to a project (standalone supplier orders) — the
        // email copy remains the canonical artifact in that case.
        let safePO = po.poNumber
            .components(separatedBy: .whitespacesAndNewlines).joined(separator: "_")
        let originalFilename = "PO_\(safePO).pdf"
        if let projectID = po.projectID {
            registerProjectDocument(
                pdfData: pdfData,
                originalFilename: originalFilename,
                projectID: projectID,
                po: po,
                store: store
            )
        }

        // Compose + dispatch.
        var recipients: [String] = [supplierEmail]
        let companyEmail = AppSettings.shared.companyEmail.trimmingCharacters(in: .whitespaces)
        if !companyEmail.isEmpty,
           companyEmail.lowercased() != supplierEmail.lowercased() {
            recipients.append(companyEmail)
        }

        let signer = AppSettings.shared.companyName.isEmpty ? "Aski IQ" : AppSettings.shared.companyName
        let body = """
        Hello,

        Please find attached Purchase Order \(po.poNumber). Total: \(po.total.currencyString).

        \(po.requiredDate.map { "Required by \(dateFormatter.string(from: $0)). " } ?? "")Reply to this email to confirm pricing and delivery.

        Thanks,
        \(signer)
        """
        let html = EmailHTMLTemplate.wrap(
            plainText:  body,
            companyName: AppSettings.shared.companyName,
            subject:    "Purchase Order \(po.poNumber)",
            footerNote: "Reply to confirm pricing and delivery."
        )

        let result = await EmailService.shared.sendPDF(
            to:          recipients,
            subject:     "Purchase Order \(po.poNumber)",
            bodyText:    body,
            bodyHTML:    html,
            replyTo:     companyEmail.isEmpty ? nil : companyEmail,
            pdfData:     pdfData,
            pdfFilename: originalFilename,
            entityType:  "purchase_order",
            entityID:    po.id
        )
        switch result {
        case .success:
            return true
        case .failure(let err):
            ToastService.shared.error("Email failed: \(err.userMessage)")
            return false
        }
    }

    // MARK: - ProjectDocument registration (idempotent)

    /// Write the rendered PDF to the app's Documents directory and
    /// register a ProjectDocument under the parent project. Removes any
    /// prior auto-generated copy for the same PO# so re-sends don't
    /// accumulate duplicates in the project's doc grid.
    private func registerProjectDocument(pdfData: Data,
                                          originalFilename: String,
                                          projectID: UUID,
                                          po: PurchaseOrder,
                                          store: AppStore) {
        let storedFileName = "\(UUID().uuidString).pdf"
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docDir.appendingPathComponent(storedFileName)
        do {
            try pdfData.write(to: url)
        } catch {
            // Non-fatal — the email still goes out, the user just won't
            // see a doc-grid copy for this send.
            print("⚠️ PurchaseOrderPDFGenerator: writing PDF to disk failed: \(error)")
            return
        }
        // Drop any prior auto-generated PDF for this PO before adding.
        for stale in store.documents(for: projectID)
            where stale.originalFileName.lowercased() == originalFilename.lowercased() {
            store.deleteDocument(stale)
        }
        let doc = ProjectDocument(
            id:               UUID(),
            projectID:        projectID,
            name:             "Purchase Order \(po.poNumber)",
            originalFileName: originalFilename,
            fileExtension:    "pdf",
            fileSize:         pdfData.count,
            storedFileName:   storedFileName,
            category:         .other,
            uploadedAt:       Date(),
            uploadedBy:       store.currentUser?.fullName ?? "System",
            notes:            "Sent to supplier."
        )
        store.addDocument(doc)
    }

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()
}
#endif
