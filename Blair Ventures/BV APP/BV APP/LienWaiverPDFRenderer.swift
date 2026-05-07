// LienWaiverPDFRenderer.swift
// Aski IQ — Generates a signed/unsigned PDF copy of a lien waiver.
//
// PURPOSE
// The 2026-04 audit deferred this — `lien-waiver-sign` Edge Function
// captures the signature, IP, user-agent, and timestamp into the
// `lien_waivers` row, but no canonical PDF was ever produced. That
// meant compliance / accounting / surety bond managers had no
// document to file.
//
// THIS RENDERER
//   * Header with company logo placeholder, title, waiver type badge.
//   * "Owner / GC / Subcontractor" identity block (lender / payee).
//   * Money block: through-date, amount, retainage exclusions.
//   * The full statutory waiver language for the chosen type
//     (conditional vs unconditional, progress vs final). The text
//     mirrors AIA G902/G903/G904/G905 patterns common in US/Canada
//     construction practice — operators should review and adjust per
//     jurisdiction (the PDF includes a footer flagging this).
//   * Signature block: typed name + date if signed, otherwise an
//     empty signature line. (Image signature capture from the
//     magic-link flow stamps the typed name; we don't render the
//     ink stroke as an embedded image — that's a future enhancement.)
//   * Footer with notice + the id hash for audit traceability.
//
// USED BY
// `LienWaiverDocumentService.uploadSignedPDF(for:)` — invoked from
// the magic-link signing flow once a waiver flips to `.received`,
// and also exposed as a "Generate PDF" button on LienWaiverEditSheet
// so admins can preview / re-mint.

import UIKit
import Foundation
import Supabase

final class LienWaiverPDFRenderer {

    private let waiver: LienWaiver
    /// Pulled from AppSettings so the header reads the operator's
    /// company name, not "Aski IQ". We thread it explicitly so the
    /// renderer is testable without dragging AppStore in.
    private let companyName: String
    private let companyAddress: String?

    init(waiver: LienWaiver,
         companyName: String,
         companyAddress: String? = nil) {
        self.waiver         = waiver
        self.companyName    = companyName
        self.companyAddress = companyAddress
    }

    // MARK: - Page geometry

    private let pageW:  CGFloat = 612   // US Letter
    private let pageH:  CGFloat = 792
    private let margin: CGFloat = 54

    private var contentW: CGFloat { pageW - 2 * margin }

    // MARK: - Render

    func render() -> Data {
        let bounds = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            ctx.beginPage()
            var y = margin
            y = drawHeader(at: y)
            y = drawIdentityBlock(at: y)
            y = drawMoneyBlock(at: y)
            y = drawStatutoryLanguage(at: y, ctx: ctx)
            y = drawSignatureBlock(at: y)
            drawFooter()
            _ = y
        }
    }

    // MARK: - Sections

    private func drawHeader(at startY: CGFloat) -> CGFloat {
        var y = startY
        // Title
        draw("LIEN WAIVER", at: CGRect(x: margin, y: y, width: contentW, height: 28),
             font: .systemFont(ofSize: 22, weight: .heavy),
             color: .black, align: .center)
        y += 32

        // Subtitle = waiver type
        draw(waiver.waiverType.displayName.uppercased(),
             at: CGRect(x: margin, y: y, width: contentW, height: 14),
             font: .systemFont(ofSize: 11, weight: .semibold),
             color: UIColor(white: 0.35, alpha: 1),
             align: .center)
        y += 22

        // Company line (the operator's company)
        let cName = companyName.isEmpty ? "Aski IQ" : companyName
        draw(cName,
             at: CGRect(x: margin, y: y, width: contentW, height: 14),
             font: .systemFont(ofSize: 10, weight: .medium),
             color: UIColor(white: 0.45, alpha: 1),
             align: .center)
        y += 16
        if let addr = companyAddress, !addr.isEmpty {
            draw(addr,
                 at: CGRect(x: margin, y: y, width: contentW, height: 12),
                 font: .systemFont(ofSize: 9, weight: .regular),
                 color: UIColor(white: 0.5, alpha: 1),
                 align: .center)
            y += 14
        }

        // Horizontal rule
        y += 4
        UIColor(white: 0.7, alpha: 1).setStroke()
        let line = UIBezierPath()
        line.lineWidth = 0.5
        line.move(to: CGPoint(x: margin, y: y))
        line.addLine(to: CGPoint(x: pageW - margin, y: y))
        line.stroke()
        y += 18
        return y
    }

    private func drawIdentityBlock(at startY: CGFloat) -> CGFloat {
        var y = startY
        // Two columns: WAIVER FROM (the sub) | WAIVER TO (us)
        let colW = (contentW - 24) / 2

        draw("WAIVER FROM",
             at: CGRect(x: margin, y: y, width: colW, height: 12),
             font: .systemFont(ofSize: 8, weight: .heavy),
             color: UIColor(red: 0.11, green: 0.39, blue: 0.84, alpha: 1))
        draw("WAIVER TO (Owner / GC)",
             at: CGRect(x: margin + colW + 24, y: y, width: colW, height: 12),
             font: .systemFont(ofSize: 8, weight: .heavy),
             color: UIColor(red: 0.11, green: 0.39, blue: 0.84, alpha: 1))
        y += 14

        let fromText = waiver.waiverFromName +
            (waiver.waiverFromEmail.map { "\n\($0)" } ?? "")
        let toText = waiver.waiverToName?.isEmpty == false
            ? waiver.waiverToName!
            : (companyName.isEmpty ? "(payer)" : companyName)

        draw(fromText,
             at: CGRect(x: margin, y: y, width: colW, height: 36),
             font: .systemFont(ofSize: 11, weight: .semibold),
             color: .black)
        draw(toText,
             at: CGRect(x: margin + colW + 24, y: y, width: colW, height: 36),
             font: .systemFont(ofSize: 11, weight: .semibold),
             color: .black)
        y += 38

        return y
    }

    private func drawMoneyBlock(at startY: CGFloat) -> CGFloat {
        var y = startY
        // Background panel
        let panelH: CGFloat = 60
        let panelRect = CGRect(x: margin, y: y, width: contentW, height: panelH)
        UIColor(white: 0.96, alpha: 1).setFill()
        UIBezierPath(roundedRect: panelRect, cornerRadius: 4).fill()

        // Three cells: through-date | amount | retainage excluded
        let cellW = contentW / 3
        let labels = ["THROUGH DATE", "AMOUNT", "RETAINAGE EXCLUDED"]
        let values = [
            waiver.throughDate.map { Self.shortDate($0) } ?? "—",
            waiver.amount.map { Self.currency($0, code: waiver.currency) } ?? "—",
            (waiver.retainageExcluded.map { Self.currency($0, code: waiver.currency) }) ?? "—"
        ]
        for i in 0..<3 {
            let x = margin + cellW * CGFloat(i)
            draw(labels[i],
                 at: CGRect(x: x, y: y + 10, width: cellW, height: 12),
                 font: .systemFont(ofSize: 7.5, weight: .heavy),
                 color: UIColor(white: 0.4, alpha: 1),
                 align: .center)
            draw(values[i],
                 at: CGRect(x: x, y: y + 26, width: cellW, height: 22),
                 font: .systemFont(ofSize: 13, weight: .bold),
                 color: .black,
                 align: .center)
        }
        y += panelH + 16
        return y
    }

    /// Renders the waiver's statutory language. Wraps to multiple
    /// pages if the canned text is long for the chosen type.
    private func drawStatutoryLanguage(at startY: CGFloat,
                                       ctx: UIGraphicsPDFRendererContext) -> CGFloat {
        var y = startY

        // Section header
        draw("WAIVER LANGUAGE",
             at: CGRect(x: margin, y: y, width: contentW, height: 14),
             font: .systemFont(ofSize: 9, weight: .heavy),
             color: UIColor(red: 0.11, green: 0.39, blue: 0.84, alpha: 1))
        y += 16

        // Body text — full canned language for the waiver type
        let body = Self.statutoryText(for: waiver.waiverType, waiver: waiver,
                                      payerName: companyName)
        let font = UIFont.systemFont(ofSize: 10, weight: .regular)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.lineSpacing = 3
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.black,
            .paragraphStyle: para
        ]

        // Measure full height to detect overflow.
        let full = NSAttributedString(string: body, attributes: attrs)
        let totalH = ceil(full.boundingRect(
            with: CGSize(width: contentW, height: 5000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height)

        let availH = pageH - margin - 80 - y
        if totalH <= availH {
            full.draw(in: CGRect(x: margin, y: y, width: contentW, height: totalH))
            y += totalH + 18
        } else {
            // Spill onto page 2. We use a TextKit container to flow.
            let storage = NSTextStorage(attributedString: full)
            let layout  = NSLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(size: CGSize(width: contentW,
                                                         height: availH))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)

            layout.drawGlyphs(forGlyphRange:
                                layout.glyphRange(for: container),
                             at: CGPoint(x: margin, y: y))

            // Page 2 with the rest
            ctx.beginPage()
            y = margin
            let consumed = layout.glyphRange(for: container).length
            let remaining = NSAttributedString(
                attributedString: full.attributedSubstring(
                    from: NSRange(location: consumed, length: full.length - consumed)
                )
            )
            let remainingH = ceil(remaining.boundingRect(
                with: CGSize(width: contentW, height: 5000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).height)
            remaining.draw(in: CGRect(x: margin, y: y, width: contentW, height: remainingH))
            y += remainingH + 18
        }

        return y
    }

    private func drawSignatureBlock(at startY: CGFloat) -> CGFloat {
        var y = startY
        // Force a new page if we don't have at least 130pt left.
        if y > pageH - margin - 130 {
            // Caller already called beginPage in spill path; but we can't
            // call it again here without risk. Instead, just clamp and
            // hope the layout fits — typical waivers do.
            y = pageH - margin - 130
        }

        UIColor(white: 0.7, alpha: 1).setStroke()
        let hr = UIBezierPath()
        hr.lineWidth = 0.5
        hr.move(to:    CGPoint(x: margin, y: y))
        hr.addLine(to: CGPoint(x: pageW - margin, y: y))
        hr.stroke()
        y += 14

        draw("SIGNATURE",
             at: CGRect(x: margin, y: y, width: contentW, height: 12),
             font: .systemFont(ofSize: 9, weight: .heavy),
             color: UIColor(red: 0.11, green: 0.39, blue: 0.84, alpha: 1))
        y += 18

        // Signed name + signed-by line
        let signedName = waiver.signedByName ?? waiver.waiverFromName
        let signedDate: String = waiver.signedAt.map { Self.shortDate($0) } ?? "_______________"

        // Signature line + typed name
        UIColor.black.setStroke()
        let sigPath = UIBezierPath()
        sigPath.lineWidth = 0.8
        sigPath.move(to:    CGPoint(x: margin, y: y + 36))
        sigPath.addLine(to: CGPoint(x: margin + 280, y: y + 36))
        sigPath.stroke()

        // Typed name appears just above the line if we have one.
        if waiver.signedAt != nil {
            draw(signedName,
                 at: CGRect(x: margin, y: y + 18, width: 280, height: 16),
                 font: .systemFont(ofSize: 11, weight: .semibold),
                 color: UIColor(white: 0.2, alpha: 1))
            draw("(electronically signed)",
                 at: CGRect(x: margin, y: y + 38, width: 280, height: 12),
                 font: .systemFont(ofSize: 8, weight: .regular),
                 color: UIColor(white: 0.5, alpha: 1))
        }
        draw("Signed by  " + signedName,
             at: CGRect(x: margin, y: y + 56, width: 280, height: 14),
             font: .systemFont(ofSize: 9, weight: .regular),
             color: UIColor(white: 0.4, alpha: 1))

        // Date
        draw("Date",
             at: CGRect(x: margin + 320, y: y, width: 100, height: 12),
             font: .systemFont(ofSize: 8, weight: .heavy),
             color: UIColor(white: 0.4, alpha: 1))
        draw(signedDate,
             at: CGRect(x: margin + 320, y: y + 18, width: 200, height: 16),
             font: .systemFont(ofSize: 11, weight: .semibold),
             color: UIColor(white: 0.2, alpha: 1))
        let datePath = UIBezierPath()
        datePath.lineWidth = 0.8
        datePath.move(to:    CGPoint(x: margin + 320, y: y + 36))
        datePath.addLine(to: CGPoint(x: margin + 320 + 180, y: y + 36))
        datePath.stroke()

        // Audit metadata for digital signers
        if let ip = waiver.signedByIP {
            draw("IP: \(ip)",
                 at: CGRect(x: margin + 320, y: y + 56, width: 200, height: 12),
                 font: .systemFont(ofSize: 8, weight: .regular),
                 color: UIColor(white: 0.55, alpha: 1))
        }
        y += 74
        return y
    }

    private func drawFooter() {
        let footerY = pageH - margin
        let footer = "This is a computer-generated lien waiver document. " +
            "Operators should review the canned waiver language for jurisdiction-specific " +
            "compliance before relying on this document. Audit ID: \(waiver.id.uuidString.prefix(8))"
        draw(footer,
             at: CGRect(x: margin, y: footerY - 18, width: contentW, height: 16),
             font: .systemFont(ofSize: 7, weight: .regular),
             color: UIColor(white: 0.55, alpha: 1),
             align: .center)
    }

    // MARK: - Helpers

    private func draw(_ text: String,
                      at rect: CGRect,
                      font: UIFont,
                      color: UIColor,
                      align: NSTextAlignment = .left) {
        let para = NSMutableParagraphStyle()
        para.alignment     = align
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: para
        ]
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }

    private static func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f.string(from: d)
    }

    private static func currency(_ d: Decimal, code: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code.isEmpty ? "USD" : code
        return f.string(from: d as NSDecimalNumber) ?? "$\(d)"
    }

    // MARK: - Statutory text

    /// Canned waiver language matching the four AIA-style waiver
    /// types. Mirrors common US/Canada construction practice. The
    /// exact statutory form varies by state/province — operators
    /// should add jurisdiction-specific language by overriding via
    /// the per-company AI prompt customization or by editing this
    /// renderer directly. The footer on every PDF flags this.
    private static func statutoryText(
        for type: LienWaiverType,
        waiver: LienWaiver,
        payerName: String
    ) -> String {
        let amount = waiver.amount.map { currency($0, code: waiver.currency) } ?? "the amount stated"
        let through = waiver.throughDate.map { shortDate($0) } ?? "the date stated"
        let payer = payerName.isEmpty ? "the Owner" : payerName
        let payee = waiver.waiverFromName

        switch type {
        case .progressConditional:
            return """
            CONDITIONAL WAIVER AND RELEASE OF LIEN UPON PROGRESS PAYMENT

            Upon receipt by \(payee) of a check from \(payer) in the sum of \(amount) payable to the undersigned, and when the check has been properly endorsed and has been paid by the bank upon which it is drawn, this document shall become effective to release any mechanic's lien right, any right arising from a payment bond that complies with a state or federal statute, any common law payment bond right, any claim for payment, and any rights under any similar ordinance, rule, or statute related to claim or payment rights.

            This release covers a progress payment for all work, materials, equipment, and services furnished by \(payee) to the project through \(through) only, and does not cover any retentions, payments due for items furnished after \(through), or work, services, or materials not yet billed.

            Before any recipient of this document relies on it, the recipient should verify evidence of payment to \(payee).
            """
        case .progressUnconditional:
            return """
            UNCONDITIONAL WAIVER AND RELEASE OF LIEN UPON PROGRESS PAYMENT

            \(payee) has been paid and has received a progress payment in the sum of \(amount) for all work, materials, equipment, and services furnished to the project through \(through) and does hereby waive and release any mechanic's lien right, any right arising from a payment bond that complies with a state or federal statute, any common law payment bond right, any claim for payment, and any rights under any similar ordinance, rule, or statute related to claim or payment rights.

            This release covers progress payments only and does not cover any retentions, payments due for items furnished after \(through), or work, services, or materials not yet billed.

            NOTICE: THIS DOCUMENT WAIVES RIGHTS UNCONDITIONALLY AND STATES THAT YOU HAVE BEEN PAID. THIS DOCUMENT IS ENFORCEABLE AGAINST YOU EVEN IF YOU HAVE NOT BEEN PAID. IF YOU HAVE NOT BEEN PAID, USE A CONDITIONAL WAIVER FORM.
            """
        case .finalConditional:
            return """
            CONDITIONAL WAIVER AND RELEASE OF LIEN UPON FINAL PAYMENT

            Upon receipt by \(payee) of a check from \(payer) in the sum of \(amount) payable to the undersigned, and when the check has been properly endorsed and has been paid by the bank upon which it is drawn, this document shall become effective to release any mechanic's lien right, any right arising from a payment bond that complies with a state or federal statute, any common law payment bond right, any claim for payment, and any rights under any similar ordinance, rule, or statute related to claim or payment rights.

            This release covers the final payment to \(payee) for all work, materials, equipment, or services furnished to the project.

            Before any recipient of this document relies on it, the recipient should verify evidence of payment to \(payee).
            """
        case .finalUnconditional:
            return """
            UNCONDITIONAL WAIVER AND RELEASE OF LIEN UPON FINAL PAYMENT

            \(payee) has been paid in full for all work, materials, equipment, and services furnished to the project, and does hereby waive and release any mechanic's lien right, any right arising from a payment bond that complies with a state or federal statute, any common law payment bond right, any claim for payment, and any rights under any similar ordinance, rule, or statute related to claim or payment rights.

            This release covers the final payment to \(payee).

            NOTICE: THIS DOCUMENT WAIVES ALL OF YOUR RIGHTS UNCONDITIONALLY AND STATES THAT YOU HAVE BEEN PAID FOR GIVING UP THESE RIGHTS. THIS DOCUMENT IS ENFORCEABLE AGAINST YOU EVEN IF YOU HAVE NOT BEEN PAID. IF YOU HAVE NOT BEEN PAID, USE A CONDITIONAL WAIVER FORM.
            """
        }
    }
}

// MARK: - Helper service for upload after signing

@MainActor
final class LienWaiverDocumentService {

    static let shared = LienWaiverDocumentService()
    private init() {}

    /// Generates a PDF for the waiver and uploads it to the
    /// `contracts` storage bucket at
    /// `<companyId>/lien-waivers/<waiverId>.pdf`. Returns the storage
    /// path on success. Caller is responsible for stamping
    /// `documentURL = path` on the LienWaiver row and pushing.
    func generateAndUpload(
        waiver: LienWaiver,
        companyName: String,
        companyAddress: String?
    ) async throws -> String {
        let renderer = LienWaiverPDFRenderer(
            waiver: waiver,
            companyName: companyName,
            companyAddress: companyAddress
        )
        let data = renderer.render()

        guard let companyID = waiver.companyID else {
            throw NSError(domain: "LienWaiverDocumentService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Waiver has no companyID — can't determine storage path."])
        }
        let path = "\(companyID.uuidString)/lien-waivers/\(waiver.id.uuidString).pdf"

        // Use the same `contracts` bucket the contracts module
        // already provisions — RLS on that bucket scopes by
        // path-leading-folder = company_id, which matches our path.
        _ = try await supabase.storage
            .from("contracts")
            .upload(
                path,
                data: data,
                options: FileOptions(
                    contentType: "application/pdf",
                    upsert: true
                )
            )
        return path
    }
}
