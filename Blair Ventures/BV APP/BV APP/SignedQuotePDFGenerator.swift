// SignedQuotePDFGenerator.swift
// Aski IQ — Post-acceptance signed quote PDF generation.
//
// FLOW
//   1. Sync engine notices a quote that flipped to .accepted server-side
//      (via the customer signing the magic link).
//   2. This generator fetches the acceptance details (signature, IP,
//      timestamp, token suffix) from get_quote_acceptance_signed_details.
//   3. Renders the standard quote PDF + an Acceptance Certificate page
//      using QuotePDFRenderer with its new acceptance: parameter.
//   4. Writes the PDF to the app's Documents directory as
//      Quote_<jobNumber>_signed.pdf and registers a ProjectDocument
//      (category: .quote) so it shows in the QuoteDocumentsSection UI.
//   5. Emails the signed PDF to the customer (acceptedByEmail) and the
//      company (AppSettings.companyEmail) via EmailService.
//
// IDEMPOTENCY
//   Tracks processed quote IDs in UserDefaults under
//   `bv_signed_pdf_processed_quote_ids`. The sync engine calls
//   ensureSignedPDF(for:) on every accepted quote on every pull; this
//   generator no-ops on quotes it has already handled. The check fires
//   BEFORE any network calls so re-pulls are cheap.
//
// COPY-TO-PROJECT / COPY-TO-SALE
//   `copyExistingSignedPDF(...)` is the entry point used by
//   convertQuoteToProject and MaterialSaleCreateEditView.save when they
//   want to attach the existing signed PDF to a new owner. Returns
//   silently when the source quote has no signed PDF yet — common
//   during conversion of quotes that were accepted before this feature
//   shipped.

#if canImport(UIKit)
import Foundation
import UIKit
import Combine   // for AppStore.objectWillChange used in the storage extension below

@MainActor
final class SignedQuotePDFGenerator {

    static let shared = SignedQuotePDFGenerator()
    private init() {}

    // MARK: - Idempotency tracking

    private let processedKey = "bv_signed_pdf_processed_quote_ids"

    private var processedQuoteIDs: Set<UUID> {
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

    private func markProcessed(_ quoteID: UUID) {
        var current = processedQuoteIDs
        current.insert(quoteID)
        processedQuoteIDs = current
    }

    // MARK: - Public entry points

    /// Idempotent: called by the sync engine for every quote that's in
    /// `.accepted` status. No-ops if this quote has already been
    /// processed (in-memory ledger keyed on UUID, persisted across
    /// launches in UserDefaults). On the first call per quote it does
    /// the full fetch → render → save → email pipeline.
    ///
    /// Errors are logged and the quote is NOT marked processed, so a
    /// transient network or rendering failure retries on the next sync.
    func ensureSignedPDF(for quote: Quote, store: AppStore) async {
        guard quote.status == .accepted else { return }
        guard !processedQuoteIDs.contains(quote.id) else { return }

        do {
            guard let details = try await QuoteAcceptanceService.shared
                .fetchSignedDetails(quoteID: quote.id) else {
                // No accepted token row yet — quote may have been moved
                // to .accepted via the status-drift fix without an
                // actual signature. Skip silently; nothing to render.
                print("ℹ️ SignedQuotePDFGenerator: no signed details for \(quote.id), skipping")
                return
            }

            let pdfData = renderSignedPDF(for: quote, store: store, details: details)
            let stored  = try persistSignedPDF(pdfData, quote: quote, store: store)

            await emailSignedPDF(
                pdfData:    pdfData,
                filename:   stored.filename,
                quote:      quote,
                customerEmail: details.acceptedByEmail,
                customerName:  details.acceptedByName
            )

            markProcessed(quote.id)
            print("✅ SignedQuotePDFGenerator: signed PDF generated + sent for \(quote.jobNumber)")
        } catch {
            // Don't mark processed — retry on next sync.
            print("⚠️ SignedQuotePDFGenerator: failed for \(quote.jobNumber): \(error)")
            CrashReporter.capture(error: error, context: [
                "operation": "ensureSignedPDF",
                "quote_id":  quote.id.uuidString,
            ])
        }
    }

    /// Copies the existing signed-PDF document (if any) onto a new
    /// owner — used when a quote is converted to a project or a
    /// material sale and the receiving record should inherit the
    /// signed PDF for its own document grid.
    ///
    /// Silently no-ops when the source quote has no signed PDF on file.
    /// `kind` controls which document store to write into.
    enum CopyTarget {
        case project(UUID)
        case materialSale(UUID)
    }

    func copyExistingSignedPDF(fromQuoteID sourceQuoteID: UUID,
                                to target: CopyTarget,
                                store: AppStore) {
        // Find the signed-PDF document on the source quote. Filename
        // suffix `_signed.pdf` is the marker we set in persistSignedPDF.
        guard let sourceDoc = store.quoteDocs(for: sourceQuoteID).first(where: {
            $0.originalFileName.lowercased().hasSuffix("_signed.pdf")
        }) else {
            // Nothing to copy — quote was either accepted before this
            // feature shipped, or the sync hasn't generated the signed
            // PDF yet. Skip silently.
            return
        }
        guard sourceDoc.fileExists else {
            print("⚠️ SignedQuotePDFGenerator: source signed PDF missing on disk for quote \(sourceQuoteID)")
            return
        }

        // Copy the file with a new UUID-named filename so the new
        // owner has independent metadata + storage. Disk is cheap and
        // independence means deleting one copy doesn't break the other.
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let newStoredName = "\(UUID().uuidString).pdf"
        let destURL = docDir.appendingPathComponent(newStoredName)
        do {
            try FileManager.default.copyItem(at: sourceDoc.storedURL, to: destURL)
        } catch {
            print("⚠️ SignedQuotePDFGenerator: copy failed: \(error)")
            return
        }

        // Build a fresh ProjectDocument record pointing at the new file.
        let ownerID: UUID
        switch target {
        case .project(let pid):      ownerID = pid
        case .materialSale(let sid): ownerID = sid
        }
        let copy = ProjectDocument(
            id:               UUID(),
            projectID:        ownerID,
            name:             sourceDoc.name,
            originalFileName: sourceDoc.originalFileName,
            fileExtension:    "pdf",
            fileSize:         sourceDoc.fileSize,
            storedFileName:   newStoredName,
            category:         .quote,
            uploadedAt:       Date(),
            uploadedBy:       store.currentUser?.fullName ?? "System",
            notes:            "Auto-copied from accepted quote."
        )

        switch target {
        case .project:
            store.addDocument(copy)
        case .materialSale:
            store.addMaterialSaleDoc(copy)
        }
    }

    // MARK: - Internals

    private func renderSignedPDF(for quote: Quote,
                                  store: AppStore,
                                  details: QuoteAcceptanceService.SignedDetails) -> Data {
        // Same line-item fallback as the existing emailPDF flow:
        // legacy quotes that pre-date stored line items pull the items
        // from their source estimate.
        let lineItems = quote.lineItems.isEmpty
            ? (store.estimates.first { $0.id == quote.estimateID }?.lineItems ?? [])
            : quote.lineItems
        let taxRate  = quote.taxRate > 0 ? quote.taxRate : Decimal(AppSettings.shared.taxRate)
        let taxLabel = AppSettings.shared.taxLabel

        let cert = QuotePDFRenderer.AcceptanceCertificate(
            acceptedAt:      details.acceptedAt,
            acceptedByName:  details.acceptedByName,
            acceptedByEmail: details.acceptedByEmail,
            acceptedIP:      details.acceptedIP,
            signaturePNG:    details.signaturePNG,
            tokenSuffix:     details.tokenSuffix
        )
        // Slice B: include attached T&C in the signed PDF too, so the
        // signed copy a customer receives matches the unsigned copy
        // (plus the appended Acceptance Certificate page).
        let attachedTerms = store.quoteTerms(for: quote.id)
        return QuotePDFRenderer(
            quote:      quote,
            lineItems:  lineItems,
            taxRate:    taxRate,
            taxLabel:   taxLabel,
            acceptance: cert,
            quoteTerms: attachedTerms
        ).render()
    }

    private struct PersistedPDF {
        let storedFileName: String
        let filename:       String
        let url:            URL
    }

    private func persistSignedPDF(_ data: Data,
                                   quote: Quote,
                                   store: AppStore) throws -> PersistedPDF {
        let safeJob  = quote.jobNumber
            .components(separatedBy: .whitespacesAndNewlines).joined(separator: "_")
        let filename = "Quote_\(safeJob)_signed.pdf"
        let storedFileName = "\(UUID().uuidString).pdf"
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docDir.appendingPathComponent(storedFileName)
        try data.write(to: url)

        // Avoid double-registering if the user has already stored this
        // signed PDF (e.g. from a prior partial run that crashed
        // mid-pipeline before the processed-ledger update).
        let existing = store.quoteDocs(for: quote.id)
            .contains { $0.originalFileName.lowercased() == filename.lowercased() }
        if !existing {
            let doc = ProjectDocument(
                id:               UUID(),
                projectID:        quote.id,
                name:             "Signed Quote \(quote.jobNumber)",
                originalFileName: filename,
                fileExtension:    "pdf",
                fileSize:         data.count,
                storedFileName:   storedFileName,
                category:         .quote,
                uploadedAt:       Date(),
                uploadedBy:       "Magic Link Acceptance",
                notes:            "Includes Acceptance Certificate page with signature, accepting party, and timestamp."
            )
            store.addQuoteDoc(doc)
        }

        return PersistedPDF(storedFileName: storedFileName, filename: filename, url: url)
    }

    private func emailSignedPDF(pdfData: Data,
                                 filename: String,
                                 quote: Quote,
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
            print("ℹ️ SignedQuotePDFGenerator: no recipients for \(quote.jobNumber); skipping email")
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
        let body = """
        \(greeting)

        Thank you for accepting quote \(quote.jobNumber). A signed copy of
        the quote — including an Acceptance Certificate page with your
        signature, name, email, IP address, and timestamp — is attached
        for your records.

        We'll be in touch shortly with next steps.

        Thanks,
        \(signature)
        """

        let html = EmailHTMLTemplate.wrap(
            plainText:  body,
            companyName: AppSettings.shared.companyName,
            subject:    "Signed Quote \(quote.jobNumber)",
            footerNote: "Reply to this email if you have any questions about the signed quote."
        )

        let result = await EmailService.shared.sendPDF(
            to:          recipients,
            subject:     "Signed Quote \(quote.jobNumber)",
            bodyText:    body,
            bodyHTML:    html,
            replyTo:     companyEmail.isEmpty ? nil : companyEmail,
            pdfData:     pdfData,
            pdfFilename: filename,
            entityType:  "quote",
            entityID:    quote.id
        )
        if case .failure(let err) = result {
            print("⚠️ SignedQuotePDFGenerator: email send failed for \(quote.jobNumber): \(err.userMessage)")
        }
    }
}

// MARK: - AppStore: Material Sale Document Storage
//
// Mirrors the addQuoteDoc / quoteDocs pattern in QuoteViews.swift,
// stored under its own UserDefaults key so material-sale docs and
// quote/project docs stay in distinct namespaces.

extension AppStore {

    var allMaterialSaleDocs: [ProjectDocument] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = UserDefaults.standard.data(forKey: "ak_material_sale_documents"),
              let docs  = try? decoder.decode([ProjectDocument].self, from: data)
        else { return [] }
        return docs
    }

    func materialSaleDocs(for saleID: UUID) -> [ProjectDocument] {
        allMaterialSaleDocs
            .filter { $0.projectID == saleID }   // projectID field reused as ownerID
            .sorted { $0.uploadedAt > $1.uploadedAt }
    }

    func addMaterialSaleDoc(_ doc: ProjectDocument) {
        var current = allMaterialSaleDocs
        if !current.contains(where: { $0.id == doc.id }) {
            current.append(doc)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(current) {
            UserDefaults.standard.set(data, forKey: "ak_material_sale_documents")
        }
        objectWillChange.send()
    }

    func deleteMaterialSaleDoc(_ doc: ProjectDocument) {
        try? FileManager.default.removeItem(at: doc.storedURL)
        var current = allMaterialSaleDocs
        current.removeAll { $0.id == doc.id }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(current) {
            UserDefaults.standard.set(data, forKey: "ak_material_sale_documents")
        }
        objectWillChange.send()
    }
}
#endif
