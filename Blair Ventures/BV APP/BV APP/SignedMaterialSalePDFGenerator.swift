// SignedMaterialSalePDFGenerator.swift
// Aski IQ — Post-acceptance signed material-sale PDF generation.
//
// Path-A clone of SignedQuotePDFGenerator. Mirrors the same flow:
// detects sales that flipped to .ordered server-side via the magic
// link, fetches signed details, renders an acceptance certificate
// page on top of the standard sale PDF, persists it as a
// ProjectDocument under the sale's namespace, and emails the signed
// copy to the customer + company inbox.
//
// IDEMPOTENCY
//   Tracks processed sale IDs in UserDefaults under
//   `bv_signed_pdf_processed_sale_ids`. The sync engine calls
//   ensureSignedPDF(for:) for every accepted sale on every pull; this
//   generator no-ops on sales it has already handled.
//
// IMPORTANT: deliberate clone of SignedQuotePDFGenerator. Do not
// refactor into a polymorphic generator without aligning with the
// master prompt — see migration header for rationale.

#if canImport(UIKit)
import Foundation
import UIKit
import Combine

@MainActor
final class SignedMaterialSalePDFGenerator {

    static let shared = SignedMaterialSalePDFGenerator()
    private init() {}

    // MARK: - Idempotency tracking

    private let processedKey = "bv_signed_pdf_processed_sale_ids"

    private var processedSaleIDs: Set<UUID> {
        get {
            guard let arr = UserDefaults.standard.array(forKey: processedKey) as? [String] else {
                return []
            }
            return Set(arr.compactMap(UUID.init(uuidString:)))
        }
        set {
            UserDefaults.standard.set(newValue.map { $0.uuidString }, forKey: processedKey)
        }
    }

    private func markProcessed(_ saleID: UUID) {
        var current = processedSaleIDs
        current.insert(saleID)
        processedSaleIDs = current
    }

    // MARK: - Public entry point

    /// Idempotent: called by the sync engine for every material sale
    /// that has `acceptedAt != nil`. No-ops on sales already
    /// processed. On first call, runs the full fetch → render → save
    /// → email pipeline.
    ///
    /// Errors are logged and the sale is NOT marked processed, so a
    /// transient network or rendering failure retries on the next sync.
    func ensureSignedPDF(for sale: MaterialSale, store: AppStore) async {
        guard sale.acceptedAt != nil else { return }
        guard !processedSaleIDs.contains(sale.id) else { return }

        do {
            guard let details = try await MaterialSaleAcceptanceService.shared
                .fetchSignedDetails(saleID: sale.id) else {
                // No accepted token row yet — sale may have been moved
                // to .ordered manually without an actual signature.
                // Skip silently.
                print("ℹ️ SignedMaterialSalePDFGenerator: no signed details for \(sale.id), skipping")
                return
            }

            let pdfData = renderSignedPDF(for: sale, store: store, details: details)
            let stored  = try persistSignedPDF(pdfData, sale: sale, store: store)

            await emailSignedPDF(
                pdfData:       pdfData,
                filename:      stored.filename,
                sale:          sale,
                customerEmail: details.acceptedByEmail,
                customerName:  details.acceptedByName
            )

            markProcessed(sale.id)
            print("✅ SignedMaterialSalePDFGenerator: signed PDF generated + sent for \(sale.saleNumber)")
        } catch {
            print("⚠️ SignedMaterialSalePDFGenerator: failed for \(sale.saleNumber): \(error)")
            CrashReporter.capture(error: error, context: [
                "operation": "ensureSignedPDF",
                "sale_id":   sale.id.uuidString,
            ])
        }
    }

    // MARK: - Internals

    private func renderSignedPDF(for sale: MaterialSale,
                                  store: AppStore,
                                  details: MaterialSaleAcceptanceService.SignedDetails) -> Data {
        let clientName = store.client(id: sale.clientID)?.name ?? "Customer"
        let deliveryAddress: String = {
            if let addr = sale.deliveryAddress, !addr.isEmpty { return addr }
            if let sid = sale.siteID,
               let site = store.client(id: sale.clientID)?.sites.first(where: { $0.id == sid }) {
                let fa = site.formattedAddress
                return fa.isEmpty ? site.address : fa
            }
            return store.client(id: sale.clientID)?.fullBillingAddress ?? ""
        }()

        let cert = MaterialSalePDFRenderer.AcceptanceCertificate(
            acceptedAt:      details.acceptedAt,
            acceptedByName:  details.acceptedByName,
            acceptedByEmail: details.acceptedByEmail,
            acceptedIP:      details.acceptedIP,
            signaturePNG:    details.signaturePNG,
            tokenSuffix:     details.tokenSuffix
        )
        let attachedTerms = store.materialSaleTerms(for: sale.id)
        return MaterialSalePDFRenderer(
            sale:            sale,
            clientName:      clientName,
            deliveryAddress: deliveryAddress,
            saleTerms:       attachedTerms,
            acceptance:      cert
        ).render()
    }

    private struct PersistedPDF {
        let storedFileName: String
        let filename:       String
        let url:            URL
    }

    private func persistSignedPDF(_ data: Data,
                                   sale: MaterialSale,
                                   store: AppStore) throws -> PersistedPDF {
        let safeNum  = sale.saleNumber
            .components(separatedBy: .whitespacesAndNewlines).joined(separator: "_")
        let docLabel: String
        switch sale.saleType {
        case .rental:        docLabel = "Rental"
        case .directInvoice: docLabel = "Invoice"
        default:             docLabel = "Sale"
        }
        let filename = "\(docLabel)_\(safeNum)_signed.pdf"
        let storedFileName = "\(UUID().uuidString).pdf"
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docDir.appendingPathComponent(storedFileName)
        try data.write(to: url)

        // Avoid double-registering if the user has already stored this
        // signed PDF (e.g. from a prior partial run that crashed
        // mid-pipeline before the processed-ledger update).
        let existing = store.materialSaleDocs(for: sale.id)
            .contains { $0.originalFileName.lowercased() == filename.lowercased() }
        if !existing {
            let doc = ProjectDocument(
                id:               UUID(),
                projectID:        sale.id,    // ownerID — namespace is materialSaleDocs
                name:             "Signed \(docLabel) \(sale.saleNumber)",
                originalFileName: filename,
                fileExtension:    "pdf",
                fileSize:         data.count,
                storedFileName:   storedFileName,
                category:         .quote,     // closest existing category
                uploadedAt:       Date(),
                uploadedBy:       "Magic Link Acceptance",
                notes:            "Includes Acceptance Certificate page with signature, accepting party, and timestamp."
            )
            store.addMaterialSaleDoc(doc)
        }

        return PersistedPDF(storedFileName: storedFileName, filename: filename, url: url)
    }

    private func emailSignedPDF(pdfData: Data,
                                 filename: String,
                                 sale: MaterialSale,
                                 customerEmail: String?,
                                 customerName: String?) async {
        var recipients: [String] = []
        var seen = Set<String>()
        if let cust = customerEmail?.trimmingCharacters(in: .whitespaces),
           !cust.isEmpty,
           seen.insert(cust.lowercased()).inserted {
            recipients.append(cust)
        }
        let companyEmail = AppSettings.shared.companyEmail.trimmingCharacters(in: .whitespaces)
        if !companyEmail.isEmpty,
           seen.insert(companyEmail.lowercased()).inserted {
            recipients.append(companyEmail)
        }
        guard !recipients.isEmpty else {
            print("ℹ️ SignedMaterialSalePDFGenerator: no recipients for \(sale.saleNumber); skipping email")
            return
        }

        let greeting: String
        if let n = customerName?.trimmingCharacters(in: .whitespaces), !n.isEmpty {
            greeting = "Hi \(n),"
        } else {
            greeting = "Hello,"
        }
        let signature = AppSettings.shared.companyName.isEmpty
            ? "Aski IQ"
            : AppSettings.shared.companyName

        let docLabel: String
        switch sale.saleType {
        case .rental:        docLabel = "rental agreement"
        case .directInvoice: docLabel = "invoice"
        default:             docLabel = "material sale"
        }

        let body = """
        \(greeting)

        Thank you for accepting \(docLabel) \(sale.saleNumber). A signed
        copy — including an Acceptance Certificate page with your
        signature, name, email, IP address, and timestamp — is attached
        for your records.

        We'll be in touch shortly with next steps.

        Thanks,
        \(signature)
        """

        let html = EmailHTMLTemplate.wrap(
            plainText:  body,
            companyName: AppSettings.shared.companyName,
            subject:    "Signed \(sale.saleNumber)",
            footerNote: "Reply to this email if you have any questions."
        )

        let result = await EmailService.shared.sendPDF(
            to:          recipients,
            subject:     "Signed \(sale.saleNumber)",
            bodyText:    body,
            bodyHTML:    html,
            replyTo:     companyEmail.isEmpty ? nil : companyEmail,
            pdfData:     pdfData,
            pdfFilename: filename,
            entityType:  "material_sale",
            entityID:    sale.id
        )
        if case .failure(let err) = result {
            print("⚠️ SignedMaterialSalePDFGenerator: email send failed for \(sale.saleNumber): \(err.userMessage)")
        }
    }
}
#endif
