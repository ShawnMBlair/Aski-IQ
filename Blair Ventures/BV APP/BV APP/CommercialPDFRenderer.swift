// CommercialPDFRenderer.swift
// BV APP – Estimate & Quote PDF Generation
// Uses the same UIGraphicsPDFRenderer approach as FormPDFRenderer / IncidentPDFRenderer

#if canImport(UIKit)
import UIKit
import Foundation

// MARK: - Shared Drawing Helpers

private final class PDFCanvas {

    // ── Page geometry ──────────────────────────────────────────────────
    let pageW:  CGFloat = 612   // US Letter
    let pageH:  CGFloat = 792
    let margin: CGFloat = 44
    var cW:     CGFloat { pageW - 2 * margin }

    // ── Brand palette ──────────────────────────────────────────────────
    let clrBlue  = UIColor(red: 0.11, green: 0.39, blue: 0.84, alpha: 1.0)
    let clrDark  = UIColor(white: 0.13, alpha: 1)
    let clrMid   = UIColor(white: 0.44, alpha: 1)
    let clrLight = UIColor(white: 0.86, alpha: 1)
    let clrGreen = UIColor(red: 0.10, green: 0.52, blue: 0.25, alpha: 1.0)

    // ── Typography ─────────────────────────────────────────────────────
    let fCo  = UIFont.systemFont(ofSize: 18, weight: .heavy)
    let fSec = UIFont.systemFont(ofSize:  9, weight: .bold)
    let fLbl = UIFont.systemFont(ofSize:  8.5, weight: .semibold)
    let fVal = UIFont.systemFont(ofSize:  9.5, weight: .regular)
    let fHdr = UIFont.systemFont(ofSize: 10,   weight: .bold)
    let fCap = UIFont.systemFont(ofSize:  7.5, weight: .regular)
    let fMon = UIFont.monospacedSystemFont(ofSize: 8.5, weight: .bold)

    var posY: CGFloat = 0
    var ctx: UIGraphicsPDFRendererContext!

    // MARK: - Primitives

    func put(_ text: String, font: UIFont, color: UIColor,
             x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
             align: NSTextAlignment = .left) {
        let para = NSMutableParagraphStyle()
        para.alignment = align
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: para
        ]
        (text as NSString).draw(in: CGRect(x: x, y: y, width: w, height: h),
                                withAttributes: attrs)
    }

    func putWrap(_ text: String, font: UIFont, color: UIColor,
                 x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: para
        ]
        (text as NSString).draw(in: CGRect(x: x, y: y, width: w, height: h + 12),
                                withAttributes: attrs)
    }

    func hr(thick: Bool, color: UIColor) {
        let path = UIBezierPath()
        path.move(to:    CGPoint(x: margin,        y: posY))
        path.addLine(to: CGPoint(x: pageW - margin, y: posY))
        color.setStroke()
        path.lineWidth = thick ? 1.5 : 0.5
        path.stroke()
        posY += thick ? 8 : 6
    }

    func drawBadge(_ text: String, color: UIColor, rightX: CGFloat, topY: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 7.5, weight: .bold),
            .foregroundColor: UIColor.white
        ]
        let sz  = (text as NSString).size(withAttributes: attrs)
        let bW  = sz.width + 10
        let bH: CGFloat = 18
        let rect = CGRect(x: rightX - bW, y: topY, width: bW, height: bH)
        color.setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 4).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 5, y: rect.minY + 3),
                                withAttributes: attrs)
    }

    func textH(_ text: String, width: CGFloat, font: UIFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para]
        return ceil((text as NSString).boundingRect(
            with: CGSize(width: width, height: 5000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs, context: nil
        ).height)
    }

    func ensureSpace(_ needed: CGFloat) {
        if posY + needed > pageH - margin - 12 {
            ctx.beginPage()
            posY = margin
        }
    }

    func decStr(_ d: Decimal) -> String {
        NSDecimalNumber(decimal: d).stringValue
    }
}

// MARK: - Quote PDF Renderer
// Professional client-facing document: header, to/from block, scope, line items, totals, payment terms.

final class QuotePDFRenderer {

    /// Optional acceptance certificate. When provided, render() appends
    /// a final "Acceptance Certificate" page after the standard quote
    /// document. Used by the post-acceptance signed-PDF generator.
    struct AcceptanceCertificate {
        let acceptedAt:      Date
        let acceptedByName:  String?
        let acceptedByEmail: String?
        let acceptedIP:      String?
        let signaturePNG:    Data?
        /// Last 6 chars of the acceptance token. Full token is never
        /// embedded — a leaked PDF must not be replayable against the
        /// acceptance endpoint.
        let tokenSuffix:     String
    }

    private let quote:       Quote
    private let lineItems:   [CostCodeItem]
    private let taxRate:     Decimal
    private let taxLabel:    String
    private let acceptance:  AcceptanceCertificate?
    /// Slice B: per-quote T&C snapshots. Renderer prints them verbatim
    /// from titleSnapshot/bodySnapshot (never reads back through the
    /// terms_templates table) so historical quotes don't drift when
    /// admins edit master templates. Empty array = no T&C section is
    /// rendered (backwards-compat with pre-Slice-B quotes).
    private let quoteTerms:  [QuoteTerm]
    private let c = PDFCanvas()

    init(quote:       Quote,
         lineItems:   [CostCodeItem],
         taxRate:     Decimal,
         taxLabel:    String,
         acceptance:  AcceptanceCertificate? = nil,
         quoteTerms:  [QuoteTerm] = []) {
        self.quote      = quote
        self.lineItems  = lineItems
        self.taxRate    = taxRate
        self.taxLabel   = taxLabel
        self.acceptance = acceptance
        self.quoteTerms = quoteTerms
    }

    // MARK: Public entry point

    func render() -> Data {
        let bounds = CGRect(x: 0, y: 0, width: c.pageW, height: c.pageH)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            c.ctx = ctx
            ctx.beginPage()
            c.posY = c.margin

            drawHeader()
            c.hr(thick: true, color: c.clrBlue)
            drawToBlock()
            c.hr(thick: false, color: c.clrLight)

            if !quote.scopeSummary.isEmpty { drawTextSection("SCOPE OF WORK",  text: quote.scopeSummary) }
            if !quote.inclusions.isEmpty   { drawTextSection("INCLUSIONS",     text: quote.inclusions)   }
            if !quote.exclusions.isEmpty   { drawTextSection("EXCLUSIONS",     text: quote.exclusions)   }
            if !quote.assumptions.isEmpty  { drawTextSection("ASSUMPTIONS",    text: quote.assumptions)  }

            if !lineItems.isEmpty          { drawLineItemsTable() }

            drawTotals()
            c.hr(thick: false, color: c.clrLight)
            drawTextSection("PAYMENT TERMS", text: quote.paymentTerms)
            // Slice B: render attached T&C between Payment Terms and
            // Validity. drawTermsAndConditions() no-ops when the array
            // is empty so legacy quotes (and quotes the user hasn't
            // attached anything to) render exactly as before.
            if !quoteTerms.isEmpty { drawTermsAndConditions() }
            drawValidityNote()
            c.hr(thick: true, color: c.clrBlue)
            drawFooter()

            // Acceptance certificate — appended only when this renderer
            // was constructed with acceptance metadata. Lives on its own
            // page so the standard quote document above is byte-for-byte
            // identical to the unsigned version a customer originally
            // received.
            if let cert = acceptance {
                ctx.beginPage()
                c.posY = c.margin
                drawAcceptanceCertificate(cert)
            }
        }
    }

    // MARK: Acceptance Certificate page

    private func drawAcceptanceCertificate(_ cert: AcceptanceCertificate) {
        // ── Page header
        c.put("ACCEPTANCE CERTIFICATE",
              font: UIFont.systemFont(ofSize: 16, weight: .bold), color: c.clrBlue,
              x: c.margin, y: c.posY, w: c.cW, h: 22)
        c.posY += 26
        c.put("Quote \(quote.jobNumber)",
              font: c.fMon, color: c.clrDark,
              x: c.margin, y: c.posY, w: c.cW, h: 14)
        c.posY += 18
        c.hr(thick: true, color: c.clrBlue)

        // ── Acceptance details — label/value grid
        let df = DateFormatter()
        df.dateStyle = .full
        df.timeStyle = .medium

        func nonEmpty(_ s: String?, fallback: String) -> String {
            let t = s?.trimmingCharacters(in: .whitespaces) ?? ""
            return t.isEmpty ? fallback : t
        }
        let pairs: [(String, String)] = [
            ("Quote Number",   quote.jobNumber),
            ("Client / Company", quote.clientName),
            ("Accepted By",    nonEmpty(cert.acceptedByName,  fallback: "—")),
            ("Email",          nonEmpty(cert.acceptedByEmail, fallback: "—")),
            ("Accepted On",    df.string(from: cert.acceptedAt)),
            ("IP Address",     nonEmpty(cert.acceptedIP,      fallback: "Not recorded")),
            ("Method",         "Accepted via secure magic link"),
            ("Token Reference", "…\(cert.tokenSuffix)"),
        ]
        let labelW: CGFloat = 130
        let valueW: CGFloat = c.cW - labelW - 12
        let rowH:   CGFloat = 22

        c.posY += 4
        for (lbl, val) in pairs {
            c.put(lbl + ":", font: c.fLbl, color: c.clrMid,
                  x: c.margin, y: c.posY + 4, w: labelW, h: 14)
            c.put(val,
                  font: UIFont.systemFont(ofSize: 10.5, weight: .regular), color: c.clrDark,
                  x: c.margin + labelW + 12, y: c.posY + 4, w: valueW, h: 14)
            c.posY += rowH
        }

        c.posY += 6
        c.hr(thick: false, color: c.clrLight)

        // ── Signature
        c.posY += 8
        c.put("CUSTOMER SIGNATURE",
              font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: c.cW, h: 14)
        c.posY += 18

        let sigBoxH: CGFloat = 140
        let sigBox  = CGRect(x: c.margin, y: c.posY, width: c.cW, height: sigBoxH)
        c.clrLight.setStroke()
        let path = UIBezierPath(roundedRect: sigBox, cornerRadius: 6)
        path.lineWidth = 0.6
        path.stroke()

        if let pngData = cert.signaturePNG, let img = UIImage(data: pngData) {
            // Letterbox the signature into the box preserving aspect.
            let scale = min((sigBox.width  - 16) / img.size.width,
                            (sigBox.height - 16) / img.size.height)
            let drawW = img.size.width  * scale
            let drawH = img.size.height * scale
            let drawX = sigBox.midX - drawW / 2
            let drawY = sigBox.midY - drawH / 2
            img.draw(in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
        } else {
            c.put("Signature image unavailable",
                  font: c.fCap, color: c.clrMid,
                  x: sigBox.minX, y: sigBox.midY - 6, w: sigBox.width, h: 14,
                  align: .center)
        }
        c.posY += sigBoxH + 10

        // ── Legal line + footer
        let legal = "By accepting this quote electronically via the secure magic link " +
                    "delivered to the email address above, the named party confirms " +
                    "agreement to the scope, pricing, and payment terms set out in " +
                    "the preceding pages. This certificate, together with the " +
                    "acceptance record stored in the Aski IQ audit log, constitutes " +
                    "evidence of acceptance."
        let legalH = c.textH(legal, width: c.cW, font: c.fCap)
        c.putWrap(legal, font: c.fCap, color: c.clrMid,
                  x: c.margin, y: c.posY, w: c.cW, h: legalH + 4)
        c.posY += legalH + 14

        let now = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        c.put("Certificate generated: \(now)  ·  Aski IQ",
              font: c.fCap, color: c.clrMid,
              x: c.margin, y: c.posY, w: c.cW, h: 12)
    }

    // MARK: Header — company name + "QUOTE" badge + job number + contact line

    private func drawHeader() {
        let settings = AppSettings.shared
        let companyName = settings.companyName.isEmpty ? "BLAIR VENTURES" : settings.companyName.uppercased()

        // Logo (top-left, 50pt square). Falls back to text-only if asset
        // is missing — never crashes on a missing image.
        let logoSize: CGFloat = 50
        var nameX = c.margin
        if let logo = UIImage(named: "AskiIQPrimaryLogo") {
            let rect = CGRect(x: c.margin, y: c.posY - 4, width: logoSize, height: logoSize)
            logo.draw(in: rect)
            nameX = c.margin + logoSize + 12
        }

        c.put(companyName, font: c.fCo, color: c.clrBlue,
              x: nameX, y: c.posY, w: c.cW - 110 - (nameX - c.margin), h: 26)

        // QUOTE badge (top-right)
        c.drawBadge("QUOTE", color: c.clrBlue,
                    rightX: c.pageW - c.margin, topY: c.posY + 4)
        c.posY += 30

        // Job number (monospaced)
        c.put(quote.jobNumber, font: c.fMon, color: c.clrDark,
              x: nameX, y: c.posY, w: c.cW - (nameX - c.margin), h: 14)
        c.posY += 16

        // Contact info line
        var parts: [String] = []
        if !settings.companyAddress.isEmpty { parts.append(settings.companyAddress) }
        if !settings.companyPhone.isEmpty   { parts.append(settings.companyPhone)   }
        if !settings.companyEmail.isEmpty   { parts.append(settings.companyEmail)   }
        if !parts.isEmpty {
            c.put(parts.joined(separator: "  |  "), font: c.fCap, color: c.clrMid,
                  x: nameX, y: c.posY, w: c.cW - (nameX - c.margin), h: 12)
            c.posY += 14
        }
        // Ensure header block clears the logo height regardless of text length.
        if c.posY < logoSize + 4 { c.posY = logoSize + 4 }
        c.posY += 4
    }

    // MARK: To Block — client (left) + dates/preparer (right)

    private func drawToBlock() {
        let col1W: CGFloat = c.cW * 0.54
        let col2X = c.margin + col1W + 20
        let col2W = c.cW - col1W - 20
        let startY = c.posY

        // Left: To
        c.put("TO:", font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: 30, h: 13)
        c.posY += 16

        c.put(quote.clientName,
              font: UIFont.systemFont(ofSize: 10.5, weight: .semibold), color: c.clrDark,
              x: c.margin, y: c.posY, w: col1W, h: 14)
        c.posY += 15

        if let addr = quote.siteAddress, !addr.isEmpty {
            let addrH = c.textH(addr, width: col1W, font: c.fVal)
            c.putWrap(addr, font: c.fVal, color: c.clrMid,
                      x: c.margin, y: c.posY, w: col1W, h: addrH + 4)
            c.posY += addrH + 6
        }

        // Right: dates + preparer
        let df = DateFormatter()
        df.dateStyle = .long; df.timeStyle = .none
        let pairs: [(String, String)] = [
            ("Date",        df.string(from: quote.quoteDate)),
            ("Valid Until", df.string(from: quote.expiryDate)),
            ("Prepared by", quote.preparedBy),
            ("Revision",    "Rev \(quote.revision)"),
        ]
        var rightY = startY
        for (lbl, val) in pairs {
            c.put(lbl + ":", font: c.fLbl, color: c.clrMid,
                  x: col2X, y: rightY, w: 72, h: 14)
            c.put(val, font: c.fVal, color: c.clrDark,
                  x: col2X + 74, y: rightY, w: col2W - 74, h: 14)
            rightY += 16
        }

        c.posY = max(c.posY, rightY) + 10
    }

    // MARK: Text Section (scope / inclusions / exclusions / payment terms)

    private func drawTextSection(_ title: String, text: String) {
        guard !text.isEmpty else { return }
        let h = c.textH(text, width: c.cW, font: c.fVal)
        c.ensureSpace(16 + h + 14)
        c.posY += 6
        c.put(title, font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: c.cW, h: 13)
        c.posY += 16
        c.putWrap(text, font: c.fVal, color: c.clrDark,
                  x: c.margin, y: c.posY, w: c.cW, h: h + 4)
        c.posY += h + 10
    }

    // MARK: Line Items Table

    private func drawLineItemsTable() {
        c.ensureSpace(50)
        c.posY += 6
        c.put("LINE ITEMS", font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: c.cW, h: 13)
        c.posY += 16

        // Column layout  |  Description  |  Unit  |  Qty  |  Rate  |  Amount  |
        let descW: CGFloat = c.cW * 0.48
        let unitW: CGFloat = c.cW * 0.09
        let qtyW:  CGFloat = c.cW * 0.09
        let rateW: CGFloat = c.cW * 0.15
        let amtW:  CGFloat = c.cW - descW - unitW - qtyW - rateW
        let col2 = c.margin + descW
        let col3 = col2 + unitW
        let col4 = col3 + qtyW
        let col5 = col4 + rateW

        // Header row background
        c.clrBlue.withAlphaComponent(0.09).setFill()
        UIRectFill(CGRect(x: c.margin, y: c.posY, width: c.cW, height: 18))

        let colDefs: [(String, CGFloat, CGFloat, NSTextAlignment)] = [
            ("Description", c.margin, descW, .left),
            ("Unit",  col2, unitW, .center),
            ("Qty",   col3, qtyW,  .right),
            ("Rate",  col4, rateW, .right),
            ("Amount",col5, amtW,  .right),
        ]
        for (title, x, w, align) in colDefs {
            c.put(title, font: c.fLbl, color: c.clrBlue,
                  x: x + 3, y: c.posY + 3, w: w - 6, h: 13, align: align)
        }
        c.posY += 20

        for (i, item) in lineItems.enumerated() {
            let descText = item.code.isEmpty ? item.description : "[\(item.code)]  \(item.description)"
            let descH = max(14, c.textH(descText, width: descW - 8, font: c.fVal))
            let rowH  = descH + 10
            c.ensureSpace(rowH + 4)

            // Alternating row tint
            if i % 2 == 0 {
                UIColor(white: 0.97, alpha: 1).setFill()
                UIRectFill(CGRect(x: c.margin, y: c.posY, width: c.cW, height: rowH))
            }

            c.putWrap(descText, font: c.fVal, color: c.clrDark,
                      x: c.margin + 3, y: c.posY + 3, w: descW - 8, h: descH)

            func rightCell(_ text: String, x: CGFloat, w: CGFloat) {
                c.put(text, font: c.fVal, color: c.clrDark,
                      x: x + 2, y: c.posY + 3, w: w - 5, h: 14, align: .right)
            }
            rightCell(item.unit,                         x: col2, w: unitW)
            rightCell(c.decStr(item.estimatedQuantity),  x: col3, w: qtyW)
            rightCell(item.unitRate.currencyString,       x: col4, w: rateW)
            rightCell(item.estimatedTotal.currencyString, x: col5, w: amtW)

            c.posY += rowH

            // Row separator
            c.clrLight.setStroke()
            let sep = UIBezierPath()
            sep.move(to:    CGPoint(x: c.margin, y: c.posY))
            sep.addLine(to: CGPoint(x: c.pageW - c.margin, y: c.posY))
            sep.lineWidth = 0.4
            sep.stroke()
        }
        c.posY += 10
    }

    // MARK: Totals block (right-aligned)

    private func drawTotals() {
        let rightW: CGFloat = 200
        let labelW: CGFloat = 120
        let valueW: CGFloat = rightW - labelW
        let rightX  = c.pageW - c.margin - rightW

        // Use model-computed chain; only re-derive tax using renderer's effective taxRate
        // (which falls back to AppSettings when quote.taxRate == 0)
        let effectiveTaxAmount = quote.totalBeforeTax * taxRate / 100
        let effectiveGrandTotal = quote.totalBeforeTax + (taxRate > 0 ? effectiveTaxAmount : 0)

        var rows: [(String, String, Bool)] = [
            ("Subtotal", quote.lineItemsSubtotal.currencyString, false),
        ]
        if quote.discountPercent > 0 {
            rows.append(("Discount (\(c.decStr(quote.discountPercent))%)",
                         "-\(quote.discountAmount.currencyString)", false))
            rows.append(("After Discount", quote.subtotalAfterDiscount.currencyString, false))
        }
        if quote.contingencyPercent > 0 {
            rows.append(("Contingency (\(c.decStr(quote.contingencyPercent))%)",
                         quote.contingencyAmount.currencyString, false))
        }
        if taxRate > 0 {
            rows.append(("Subtotal (excl. \(taxLabel))", quote.totalBeforeTax.currencyString, false))
            rows.append(("\(taxLabel) (\(c.decStr(taxRate))%)", effectiveTaxAmount.currencyString, false))
        }
        rows.append(("TOTAL", effectiveGrandTotal.currencyString, true))

        let rowH: CGFloat = 20
        c.ensureSpace(CGFloat(rows.count) * rowH + 16)
        c.posY += 6

        for (label, value, isBold) in rows {
            if isBold {
                c.clrBlue.withAlphaComponent(0.09).setFill()
                UIRectFill(CGRect(x: rightX - 8, y: c.posY, width: rightW + 8, height: rowH))
            }
            let font  = isBold ? UIFont.systemFont(ofSize: 10, weight: .bold)
                                : UIFont.systemFont(ofSize: 9.5, weight: .regular)
            let color = isBold ? c.clrBlue : c.clrMid

            c.put(label, font: c.fLbl, color: color,
                  x: rightX, y: c.posY + 3, w: labelW, h: 14, align: .right)
            c.put(value, font: font, color: c.clrDark,
                  x: rightX + labelW + 4, y: c.posY + 3, w: valueW - 4, h: 14, align: .right)
            c.posY += rowH
        }
        c.posY += 8
    }

    // MARK: Validity note

    private func drawValidityNote() {
        let df = DateFormatter()
        df.dateStyle = .long; df.timeStyle = .none
        let note = "This quote is valid for \(quote.validityDays) days from the date of issue " +
                   "(expires \(df.string(from: quote.expiryDate))). " +
                   "Acceptance of this quote constitutes agreement to the payment terms and conditions stated above."
        let h = c.textH(note, width: c.cW, font: c.fCap)
        c.ensureSpace(h + 20)
        c.posY += 8
        c.putWrap(note, font: c.fCap, color: c.clrMid, x: c.margin, y: c.posY, w: c.cW, h: h + 4)
        c.posY += h + 12
    }

    // MARK: Terms & Conditions (Slice B)

    /// Renders each attached term in display order. Each term gets its
    /// own block with a bold title (and version badge if from a
    /// template), the wrapped body, and a thin separator. ensureSpace
    /// before each block so long bodies trigger a page break instead
    /// of overflowing the page footer.
    private func drawTermsAndConditions() {
        // Section header — match the styling of PAYMENT TERMS / SCOPE
        c.ensureSpace(40)
        c.posY += 4
        c.put("TERMS & CONDITIONS",
              font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: c.cW, h: 13)
        c.posY += 18

        let titleFont = UIFont.systemFont(ofSize: 11, weight: .bold)
        let versionFont = UIFont.systemFont(ofSize: 8.5, weight: .regular)

        for (idx, term) in quoteTerms.sorted(by: { $0.displayOrder < $1.displayOrder }).enumerated() {
            // Pre-measure to decide if we need a page break before
            // this block. Reserve room for the title (~16pt), body
            // (computed), separator (8pt), and a small bottom pad.
            let bodyH = c.textH(term.bodySnapshot, width: c.cW, font: c.fVal)
            let blockH = 18 + bodyH + 14
            // If the entire block won't fit AND we're past the top of
            // the page, break to a fresh page so the title doesn't
            // get orphaned at the bottom.
            if c.posY + 18 > c.pageH - c.margin - 12 {
                c.ensureSpace(blockH)
            }

            // Title row: title (left) + version badge (right) when
            // present. Custom terms get a subtle "CUSTOM" tag.
            c.put(term.titleSnapshot,
                  font: titleFont, color: c.clrDark,
                  x: c.margin, y: c.posY, w: c.cW - 60, h: 16)

            if term.isCustom {
                c.put("CUSTOM",
                      font: versionFont, color: c.clrMid,
                      x: c.margin, y: c.posY, w: c.cW, h: 16, align: .right)
            } else if let v = term.versionSnapshot {
                c.put("v\(v)",
                      font: versionFont, color: c.clrMid,
                      x: c.margin, y: c.posY, w: c.cW, h: 16, align: .right)
            }
            c.posY += 18

            // Body — wrapped, dark text. ensureSpace on each chunk
            // would be ideal for very long terms; the simpler version
            // here pages cleanly via the title-level guard above.
            c.putWrap(term.bodySnapshot,
                      font: c.fVal, color: c.clrDark,
                      x: c.margin, y: c.posY, w: c.cW, h: bodyH + 4)
            c.posY += bodyH + 8

            // Thin separator between terms (skip after the last one)
            if idx < quoteTerms.count - 1 {
                c.clrLight.setStroke()
                let sep = UIBezierPath()
                sep.move(to:    CGPoint(x: c.margin,        y: c.posY))
                sep.addLine(to: CGPoint(x: c.pageW - c.margin, y: c.posY))
                sep.lineWidth = 0.4
                sep.stroke()
                c.posY += 8
            }
        }
        c.posY += 6
    }

    // MARK: Footer

    private func drawFooter() {
        let now = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        c.put("Generated: \(now)  ·  Aski IQ",
              font: c.fCap, color: c.clrMid,
              x: c.margin, y: c.posY + 4, w: c.cW, h: 12)
    }
}


// MARK: - Estimate PDF Renderer
// Internal cost breakdown document: line items with cost codes, margins, internal notes.

final class EstimatePDFRenderer {

    /// `internalCopy` includes contingency, overhead, profit-margin breakdown.
    /// `clientCopy` redacts those rows and shows only Subtotal → Total —
    /// safe to share with a client without leaking your margin.
    enum Variant { case internalCopy, clientCopy }

    private let estimate:    Estimate
    private let clientName:  String
    private let variant:     Variant
    /// Snapshotted T&C rows attached to this estimate. Renderer walks
    /// them in display_order and draws the body verbatim — no live
    /// template lookup, ensuring historical wording stays frozen.
    private let estimateTerms: [EstimateTerm]
    private let c = PDFCanvas()

    init(estimate: Estimate,
         clientName: String,
         variant: Variant = .internalCopy,
         estimateTerms: [EstimateTerm] = []) {
        self.estimate      = estimate
        self.clientName    = clientName
        self.variant       = variant
        self.estimateTerms = estimateTerms
    }

    func render() -> Data {
        let bounds = CGRect(x: 0, y: 0, width: c.pageW, height: c.pageH)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            c.ctx = ctx
            ctx.beginPage()
            c.posY = c.margin

            drawHeader()
            c.hr(thick: true, color: c.clrBlue)
            drawMetaBlock()
            c.hr(thick: false, color: c.clrLight)
            if let scope = estimate.scopeDescription, !scope.isEmpty {
                drawTextSection("SCOPE", text: scope)
            }
            drawLineItemsTable()
            drawCostBreakdown()
            if let notes = estimate.notes, !notes.isEmpty {
                c.hr(thick: false, color: c.clrLight)
                drawTextSection("NOTES", text: notes)
            }
            // T&C — drawn after notes, before the bottom rule. No-ops
            // when no terms are attached.
            if !estimateTerms.isEmpty {
                c.hr(thick: false, color: c.clrLight)
                drawTermsAndConditions()
            }
            c.hr(thick: true, color: c.clrBlue)
            drawFooter()
        }
    }

    // MARK: T&C section

    /// Same shape as QuotePDFRenderer.drawTermsAndConditions — kept
    /// in sync with the quote renderer so the PDFs look consistent.
    private func drawTermsAndConditions() {
        c.ensureSpace(40)
        c.posY += 4
        c.put("TERMS & CONDITIONS",
              font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: c.cW, h: 13)
        c.posY += 18

        let titleFont = UIFont.systemFont(ofSize: 11, weight: .bold)
        let versionFont = UIFont.systemFont(ofSize: 8.5, weight: .regular)

        let sorted = estimateTerms.sorted(by: { $0.displayOrder < $1.displayOrder })
        for (idx, term) in sorted.enumerated() {
            let bodyH = c.textH(term.bodySnapshot, width: c.cW, font: c.fVal)
            let blockH = 18 + bodyH + 14
            if c.posY + 18 > c.pageH - c.margin - 12 {
                c.ensureSpace(blockH)
            }

            c.put(term.titleSnapshot,
                  font: titleFont, color: c.clrDark,
                  x: c.margin, y: c.posY, w: c.cW - 60, h: 16)

            if term.isCustom {
                c.put("CUSTOM",
                      font: versionFont, color: c.clrMid,
                      x: c.margin, y: c.posY, w: c.cW, h: 16, align: .right)
            } else if let v = term.versionSnapshot {
                c.put("v\(v)",
                      font: versionFont, color: c.clrMid,
                      x: c.margin, y: c.posY, w: c.cW, h: 16, align: .right)
            }
            c.posY += 18

            c.putWrap(term.bodySnapshot,
                      font: c.fVal, color: c.clrDark,
                      x: c.margin, y: c.posY, w: c.cW, h: bodyH + 4)
            c.posY += bodyH + 8

            if idx < sorted.count - 1 {
                c.clrLight.setStroke()
                let sep = UIBezierPath()
                sep.move(to:    CGPoint(x: c.margin,        y: c.posY))
                sep.addLine(to: CGPoint(x: c.pageW - c.margin, y: c.posY))
                sep.lineWidth = 0.4
                sep.stroke()
                c.posY += 8
            }
        }
        c.posY += 6
    }

    // MARK: Header

    private func drawHeader() {
        let settings = AppSettings.shared
        let companyName = settings.companyName.isEmpty ? "BLAIR VENTURES" : settings.companyName.uppercased()

        // Logo — same shape as Quote PDF for consistent branding.
        let logoSize: CGFloat = 50
        var nameX = c.margin
        if let logo = UIImage(named: "AskiIQPrimaryLogo") {
            let rect = CGRect(x: c.margin, y: c.posY - 4, width: logoSize, height: logoSize)
            logo.draw(in: rect)
            nameX = c.margin + logoSize + 12
        }

        c.put(companyName, font: c.fCo, color: c.clrBlue,
              x: nameX, y: c.posY, w: c.cW - 130 - (nameX - c.margin), h: 26)

        // Variant badge — INTERNAL ESTIMATE for cost-detail copy,
        // ESTIMATE for client-safe copy (no margin/profit rows).
        let badgeText  = (variant == .internalCopy) ? "INTERNAL ESTIMATE" : "ESTIMATE"
        let badgeColor: UIColor = (variant == .internalCopy) ? .systemIndigo : .systemBlue
        c.drawBadge(badgeText, color: badgeColor,
                    rightX: c.pageW - c.margin, topY: c.posY + 4)
        c.posY += 30

        c.put(estimate.jobNumber, font: c.fMon, color: c.clrDark,
              x: nameX, y: c.posY, w: c.cW - (nameX - c.margin), h: 14)
        c.posY += 16

        var parts: [String] = []
        if !settings.companyAddress.isEmpty { parts.append(settings.companyAddress) }
        if !settings.companyPhone.isEmpty   { parts.append(settings.companyPhone) }
        if !parts.isEmpty {
            c.put(parts.joined(separator: "  |  "), font: c.fCap, color: c.clrMid,
                  x: nameX, y: c.posY, w: c.cW - (nameX - c.margin), h: 12)
            c.posY += 14
        }
        if c.posY < logoSize + 4 { c.posY = logoSize + 4 }
        c.posY += 4
    }

    // MARK: Meta block — client, type, status, dates

    private func drawMetaBlock() {
        let col1W: CGFloat = c.cW * 0.54
        let col2X = c.margin + col1W + 20
        let col2W = c.cW - col1W - 20
        let startY = c.posY

        // Left column
        c.put("CLIENT:", font: c.fSec, color: c.clrBlue, x: c.margin, y: c.posY, w: 60, h: 13)
        c.posY += 16
        c.put(clientName,
              font: UIFont.systemFont(ofSize: 10.5, weight: .semibold), color: c.clrDark,
              x: c.margin, y: c.posY, w: col1W, h: 14)
        c.posY += 15
        c.put(estimate.name, font: c.fVal, color: c.clrMid,
              x: c.margin, y: c.posY, w: col1W, h: 14)
        c.posY += 15

        // Right column
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
        var rightY = startY
        let pairs: [(String, String)] = [
            ("Status",      estimate.status.displayName),
            ("Revision",    "Rev \(estimate.revisionNumber)"),
            ("Type",        estimate.pricingType.displayName),
            ("Opportunity", estimate.opportunityType.displayName),
        ] + (estimate.bidDueDate.map { [("Bid Due", df.string(from: $0))] } ?? [])
          + (estimate.estimatorID != nil
             ? [("Estimator ID", estimate.estimatorID!.uuidString.prefix(8).uppercased())]
             : [])

        for (lbl, val) in pairs {
            c.put(lbl + ":", font: c.fLbl, color: c.clrMid,
                  x: col2X, y: rightY, w: 80, h: 14)
            c.put(val, font: c.fVal, color: c.clrDark,
                  x: col2X + 82, y: rightY, w: col2W - 82, h: 14)
            rightY += 16
        }

        c.posY = max(c.posY, rightY) + 10
    }

    // MARK: Text Section

    private func drawTextSection(_ title: String, text: String) {
        let h = c.textH(text, width: c.cW, font: c.fVal)
        c.ensureSpace(16 + h + 14)
        c.posY += 6
        c.put(title, font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: c.cW, h: 13)
        c.posY += 16
        c.putWrap(text, font: c.fVal, color: c.clrDark,
                  x: c.margin, y: c.posY, w: c.cW, h: h + 4)
        c.posY += h + 10
    }

    // MARK: Line Items Table (includes cost code column)

    private func drawLineItemsTable() {
        guard !estimate.lineItems.isEmpty else { return }
        c.ensureSpace(50)
        c.posY += 6
        c.put("COST BREAKDOWN", font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: c.cW, h: 13)
        c.posY += 16

        // Columns: Code | Description | Unit | Qty | Unit Rate | Total
        let codeW: CGFloat = c.cW * 0.11
        let descW: CGFloat = c.cW * 0.37
        let unitW: CGFloat = c.cW * 0.08
        let qtyW:  CGFloat = c.cW * 0.09
        let rateW: CGFloat = c.cW * 0.15
        let amtW:  CGFloat = c.cW - codeW - descW - unitW - qtyW - rateW
        let col2 = c.margin + codeW
        let col3 = col2 + descW
        let col4 = col3 + unitW
        let col5 = col4 + qtyW
        let col6 = col5 + rateW

        // Header
        c.clrBlue.withAlphaComponent(0.09).setFill()
        UIRectFill(CGRect(x: c.margin, y: c.posY, width: c.cW, height: 18))

        let colDefs: [(String, CGFloat, CGFloat, NSTextAlignment)] = [
            ("Code",  c.margin, codeW, .left),
            ("Description", col2, descW, .left),
            ("Unit",  col3, unitW, .center),
            ("Qty",   col4, qtyW,  .right),
            ("Rate",  col5, rateW, .right),
            ("Total", col6, amtW,  .right),
        ]
        for (title, x, w, align) in colDefs {
            c.put(title, font: c.fLbl, color: c.clrBlue,
                  x: x + 2, y: c.posY + 3, w: w - 4, h: 13, align: align)
        }
        c.posY += 20

        for (i, item) in estimate.lineItems.enumerated() {
            let descH = max(14, c.textH(item.description, width: descW - 6, font: c.fVal))
            let rowH  = descH + 10
            c.ensureSpace(rowH + 4)

            if i % 2 == 0 {
                UIColor(white: 0.97, alpha: 1).setFill()
                UIRectFill(CGRect(x: c.margin, y: c.posY, width: c.cW, height: rowH))
            }

            c.put(item.code, font: c.fVal, color: c.clrMid,
                  x: c.margin + 2, y: c.posY + 3, w: codeW - 4, h: 14)
            c.putWrap(item.description, font: c.fVal, color: c.clrDark,
                      x: col2 + 2, y: c.posY + 3, w: descW - 6, h: descH)

            func rCell(_ text: String, x: CGFloat, w: CGFloat) {
                c.put(text, font: c.fVal, color: c.clrDark,
                      x: x + 2, y: c.posY + 3, w: w - 4, h: 14, align: .right)
            }
            rCell(item.unit,                         x: col3, w: unitW)
            rCell(c.decStr(item.estimatedQuantity),  x: col4, w: qtyW)
            rCell(item.unitRate.currencyString,       x: col5, w: rateW)
            rCell(item.estimatedTotal.currencyString, x: col6, w: amtW)

            c.posY += rowH
            c.clrLight.setStroke()
            let sep = UIBezierPath()
            sep.move(to:    CGPoint(x: c.margin,        y: c.posY))
            sep.addLine(to: CGPoint(x: c.pageW - c.margin, y: c.posY))
            sep.lineWidth = 0.4
            sep.stroke()
        }
        c.posY += 10
    }

    // MARK: Cost Breakdown (subtotal → margins → total)

    private func drawCostBreakdown() {
        let rightW: CGFloat = 200
        let labelW: CGFloat = 125
        let valueW  = rightW - labelW
        let rightX  = c.pageW - c.margin - rightW

        // Client copy hides margin/profit/overhead/contingency breakdown — only
        // Subtotal and Total are shown. Internal copy shows everything.
        var rows: [(String, String, Bool)] = [
            ("Subtotal", estimate.subtotal.currencyString, false),
        ]
        if variant == .internalCopy {
            if estimate.contingencyPercent > 0 {
                rows.append(("Contingency (\(c.decStr(estimate.contingencyPercent))%)",
                             estimate.contingencyAmount.currencyString, false))
            }
            if estimate.overheadPercent > 0 {
                rows.append(("Overhead (\(c.decStr(estimate.overheadPercent))%)",
                             estimate.overheadAmount.currencyString, false))
            }
            if estimate.profitPercent > 0 {
                rows.append(("Profit (\(c.decStr(estimate.profitPercent))%)",
                             estimate.profitAmount.currencyString, false))
            }
        }
        let totalLabel = (variant == .internalCopy) ? "TOTAL ESTIMATED" : "TOTAL"
        rows.append((totalLabel, estimate.totalEstimated.currencyString, true))

        let rowH: CGFloat = 20
        c.ensureSpace(CGFloat(rows.count) * rowH + 16)
        c.posY += 6

        for (label, value, isBold) in rows {
            if isBold {
                c.clrBlue.withAlphaComponent(0.09).setFill()
                UIRectFill(CGRect(x: rightX - 8, y: c.posY, width: rightW + 8, height: rowH))
            }
            let font  = isBold ? UIFont.systemFont(ofSize: 10, weight: .bold)
                                : UIFont.systemFont(ofSize: 9.5, weight: .regular)
            let color = isBold ? c.clrBlue : c.clrMid

            c.put(label, font: c.fLbl, color: color,
                  x: rightX, y: c.posY + 3, w: labelW, h: 14, align: .right)
            c.put(value, font: font, color: c.clrDark,
                  x: rightX + labelW + 4, y: c.posY + 3, w: valueW - 4, h: 14, align: .right)
            c.posY += rowH
        }
        c.posY += 8
    }

    // MARK: Footer

    private func drawFooter() {
        let now = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        let suffix = (variant == .internalCopy) ? "INTERNAL USE ONLY" : "Estimate is valid for 30 days from issue."
        c.put("Generated: \(now)  ·  \(suffix)",
              font: c.fCap, color: c.clrMid,
              x: c.margin, y: c.posY + 4, w: c.cW, h: 12)
    }
}

// MARK: - Material Sale PDF Renderer
// Client-facing sale document: header, deliver-to block, line items
// table, totals, T&C, footer. Sized for "send the customer a quote
// for these materials" — sits between an Estimate (internal/bid) and
// an Invoice (post-delivery billing).
// The same renderer covers all SaleType values (project work, service
// work, material sale, rental, direct invoice) — the badge text
// adapts to make the document read naturally for each type.

final class MaterialSalePDFRenderer {

    /// Optional acceptance certificate. When provided, render() appends
    /// a final "Acceptance Certificate" page after the standard sale
    /// document. Used by the post-acceptance signed-PDF generator.
    /// Mirrors QuotePDFRenderer.AcceptanceCertificate.
    struct AcceptanceCertificate {
        let acceptedAt:      Date
        let acceptedByName:  String?
        let acceptedByEmail: String?
        let acceptedIP:      String?
        let signaturePNG:    Data?
        /// Last 6 chars of the acceptance token. Full token is never
        /// embedded — a leaked PDF must not be replayable against the
        /// acceptance endpoint.
        let tokenSuffix:     String
    }

    private let sale:        MaterialSale
    private let clientName:  String
    private let deliveryAddress: String
    /// Snapshotted T&C rows attached to this sale. Renderer walks them
    /// in display_order and prints them verbatim — no live template
    /// lookup, ensuring historical wording stays frozen.
    private let saleTerms:   [MaterialSaleTerm]
    private let acceptance:  AcceptanceCertificate?
    private let c = PDFCanvas()

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    init(sale: MaterialSale,
         clientName: String,
         deliveryAddress: String = "",
         saleTerms: [MaterialSaleTerm] = [],
         acceptance: AcceptanceCertificate? = nil) {
        self.sale = sale
        self.clientName = clientName
        self.deliveryAddress = deliveryAddress
        self.saleTerms = saleTerms
        self.acceptance = acceptance
    }

    // MARK: Public entry point

    func render() -> Data {
        let bounds = CGRect(x: 0, y: 0, width: c.pageW, height: c.pageH)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            c.ctx = ctx
            ctx.beginPage()
            c.posY = c.margin

            drawHeader()
            c.hr(thick: true, color: c.clrBlue)
            drawDeliverToBlock()
            c.hr(thick: false, color: c.clrLight)
            drawLineItemsTable()
            c.hr(thick: false, color: c.clrLight)
            drawTotals()
            if let notes = sale.notes, !notes.isEmpty {
                c.hr(thick: false, color: c.clrLight)
                drawNotes(notes)
            }
            // T&C — drawn after notes, before the bottom rule.
            // No-ops when no terms are attached.
            if !saleTerms.isEmpty {
                c.hr(thick: false, color: c.clrLight)
                drawTermsAndConditions()
            }
            c.hr(thick: true, color: c.clrBlue)
            drawFooter()

            // Acceptance Certificate — only renders for signed PDFs.
            // Forced new page so it stands alone for legal clarity.
            if let cert = acceptance {
                ctx.beginPage()
                c.posY = c.margin
                drawAcceptanceCertificate(cert)
            }
        }
    }

    // MARK: Acceptance Certificate page (signed copies only)

    private func drawAcceptanceCertificate(_ cert: AcceptanceCertificate) {
        // Header
        c.put("ACCEPTANCE CERTIFICATE",
              font: c.fCo, color: c.clrBlue,
              x: c.margin, y: c.posY, w: c.cW, h: 26)
        c.posY += 30
        c.hr(thick: true, color: c.clrBlue)

        c.put("This page certifies that the material sale above was reviewed and accepted via Aski IQ's secure magic-link acceptance flow.",
              font: c.fVal, color: c.clrDark,
              x: c.margin, y: c.posY, w: c.cW, h: 28)
        c.posY += 32
        c.hr(thick: false, color: c.clrLight)

        // Sale summary
        let saleHeader = "Sale: \(sale.saleNumber)"
        c.put(saleHeader, font: c.fHdr, color: c.clrDark,
              x: c.margin, y: c.posY, w: c.cW, h: 16)
        c.posY += 18

        // Acceptance metadata
        let dateF = DateFormatter()
        dateF.dateStyle = .medium
        dateF.timeStyle = .short

        let rows: [(String, String)] = [
            ("Accepted at",    dateF.string(from: cert.acceptedAt)),
            ("Accepted by",    cert.acceptedByName ?? "—"),
            ("Email",          cert.acceptedByEmail ?? "—"),
            ("IP address",     cert.acceptedIP ?? "—"),
            ("Token suffix",   "…\(cert.tokenSuffix)")
        ]
        for (label, value) in rows {
            c.ensureSpace(20)
            c.put(label, font: c.fLbl, color: c.clrMid,
                  x: c.margin, y: c.posY, w: 130, h: 14)
            c.put(value, font: c.fVal, color: c.clrDark,
                  x: c.margin + 140, y: c.posY, w: c.cW - 140, h: 14)
            c.posY += 18
        }

        c.posY += 8
        c.hr(thick: false, color: c.clrLight)

        // Signature image (if captured)
        c.put("SIGNATURE", font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: c.cW, h: 13)
        c.posY += 18
        if let pngData = cert.signaturePNG, let img = UIImage(data: pngData) {
            let maxW: CGFloat = 280
            let maxH: CGFloat = 110
            let aspect = img.size.height / max(img.size.width, 1)
            let drawW = min(maxW, img.size.width)
            let drawH = min(maxH, drawW * aspect)
            img.draw(in: CGRect(x: c.margin, y: c.posY, width: drawW, height: drawH))
            c.posY += drawH + 6
        } else {
            c.put("(signature not captured)",
                  font: c.fCap, color: c.clrMid,
                  x: c.margin, y: c.posY, w: c.cW, h: 12)
            c.posY += 16
        }

        c.posY += 8
        c.hr(thick: true, color: c.clrBlue)
        c.put("Generated: \(dateF.string(from: Date()))  ·  Aski IQ",
              font: c.fCap, color: c.clrMid,
              x: c.margin, y: c.posY + 4, w: c.cW, h: 12)
    }

    // MARK: Header

    private func drawHeader() {
        let settings = AppSettings.shared
        let companyName = settings.companyName.isEmpty ? "BLAIR VENTURES" : settings.companyName.uppercased()

        let logoSize: CGFloat = 50
        var nameX = c.margin
        if let logo = UIImage(named: "AskiIQPrimaryLogo") {
            let rect = CGRect(x: c.margin, y: c.posY - 4, width: logoSize, height: logoSize)
            logo.draw(in: rect)
            nameX = c.margin + logoSize + 12
        }

        c.put(companyName, font: c.fCo, color: c.clrBlue,
              x: nameX, y: c.posY, w: c.cW - 130 - (nameX - c.margin), h: 26)

        // Badge text adapts to the sale type so the document reads
        // naturally — "MATERIAL SALE" / "RENTAL AGREEMENT" / etc.
        let badgeText = badgeForSaleType()
        c.drawBadge(badgeText, color: c.clrBlue,
                    rightX: c.pageW - c.margin, topY: c.posY + 4)
        c.posY += 30

        c.put(sale.saleNumber, font: c.fMon, color: c.clrDark,
              x: nameX, y: c.posY, w: c.cW - (nameX - c.margin), h: 14)
        c.posY += 16

        var parts: [String] = []
        if !settings.companyAddress.isEmpty { parts.append(settings.companyAddress) }
        if !settings.companyPhone.isEmpty   { parts.append(settings.companyPhone) }
        if !parts.isEmpty {
            c.put(parts.joined(separator: "  |  "), font: c.fCap, color: c.clrMid,
                  x: nameX, y: c.posY, w: c.cW - (nameX - c.margin), h: 12)
            c.posY += 14
        }
        if c.posY < logoSize + 4 { c.posY = logoSize + 4 }

        // Issue date + (if set) requested delivery date — right-aligned
        // small print, mirroring the Invoice renderer's layout.
        let issued = "Issued: \(dateFormatter.string(from: sale.createdAt))"
        c.put(issued, font: c.fVal, color: c.clrMid,
              x: c.pageW - c.margin - 260, y: c.posY, w: 260, h: 14, align: .right)
        c.posY += 14
        if let req = sale.requestedDeliveryDate {
            let reqStr = "Requested: \(dateFormatter.string(from: req))"
            c.put(reqStr, font: c.fVal, color: c.clrMid,
                  x: c.pageW - c.margin - 260, y: c.posY, w: 260, h: 14, align: .right)
            c.posY += 14
        }
        c.posY += 4
    }

    private func badgeForSaleType() -> String {
        switch sale.saleType {
        case .projectWork:   return "PROJECT QUOTE"
        case .serviceWork:   return "SERVICE QUOTE"
        case .materialSale:  return "MATERIAL SALE"
        case .rental:        return "RENTAL AGREEMENT"
        case .directInvoice: return "INVOICE"
        }
    }

    // MARK: Deliver-To Block

    private func drawDeliverToBlock() {
        c.put("DELIVER TO", font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: 100, h: 12)
        c.posY += 14

        if !clientName.isEmpty {
            c.put(clientName, font: c.fHdr, color: c.clrDark,
                  x: c.margin, y: c.posY, w: 300, h: 14)
            c.posY += 14
        }

        if !deliveryAddress.isEmpty {
            let addrLines = deliveryAddress.components(separatedBy: "\n")
            for line in addrLines where !line.isEmpty {
                c.put(line, font: c.fVal, color: c.clrMid,
                      x: c.margin, y: c.posY, w: 300, h: 12)
                c.posY += 12
            }
        } else if let fallback = sale.deliveryAddress, !fallback.isEmpty {
            // Caller didn't pass a resolved address; fall back to
            // whatever's on the sale itself (free-text).
            c.put(fallback, font: c.fVal, color: c.clrMid,
                  x: c.margin, y: c.posY, w: 300, h: 12)
            c.posY += 12
        }

        c.posY += 6
    }

    // MARK: Line Items Table

    private func drawLineItemsTable() {
        c.ensureSpace(60)

        // Column geometry — same proportions as Invoice renderer
        let col1X = c.margin
        let col1W: CGFloat = c.cW * 0.50  // Description
        let col2X = col1X + col1W
        let col2W: CGFloat = c.cW * 0.10  // Qty
        let col3X = col2X + col2W
        let col3W: CGFloat = c.cW * 0.15  // Unit price
        let col4X = col3X + col3W
        let col4W: CGFloat = c.cW * 0.25  // Line total (right-aligned)

        // Header row
        c.clrLight.setFill()
        UIBezierPath(rect: CGRect(x: c.margin, y: c.posY, width: c.cW, height: 18)).fill()
        c.put("DESCRIPTION", font: c.fLbl, color: c.clrDark,
              x: col1X + 4, y: c.posY + 4, w: col1W, h: 12)
        c.put("QTY", font: c.fLbl, color: c.clrDark,
              x: col2X, y: c.posY + 4, w: col2W, h: 12, align: .center)
        c.put("UNIT PRICE", font: c.fLbl, color: c.clrDark,
              x: col3X, y: c.posY + 4, w: col3W, h: 12, align: .right)
        c.put("TOTAL", font: c.fLbl, color: c.clrDark,
              x: col4X, y: c.posY + 4, w: col4W - 4, h: 12, align: .right)
        c.posY += 20

        for item in sale.lineItems {
            let bodyH = c.textH(item.description, width: col1W - 4, font: c.fVal)
            let rowH  = max(18, bodyH + 6)

            c.ensureSpace(rowH + 4)

            c.putWrap(item.description, font: c.fVal, color: c.clrDark,
                      x: col1X + 4, y: c.posY + 2, w: col1W - 4, h: rowH)
            let qtyStr = "\(c.decStr(item.quantity)) \(item.unit)"
            c.put(qtyStr, font: c.fVal, color: c.clrMid,
                  x: col2X, y: c.posY + 2, w: col2W, h: 14, align: .center)
            c.put(item.unitPrice.currencyString, font: c.fVal, color: c.clrDark,
                  x: col3X, y: c.posY + 2, w: col3W, h: 14, align: .right)
            c.put(item.lineTotal.currencyString, font: c.fVal, color: c.clrDark,
                  x: col4X, y: c.posY + 2, w: col4W - 4, h: 14, align: .right)

            c.posY += rowH

            // Thin separator
            c.clrLight.setStroke()
            let sep = UIBezierPath()
            sep.move(to:    CGPoint(x: c.margin,        y: c.posY))
            sep.addLine(to: CGPoint(x: c.pageW - c.margin, y: c.posY))
            sep.lineWidth = 0.3
            sep.stroke()
            c.posY += 4
        }
    }

    // MARK: Totals

    private func drawTotals() {
        c.ensureSpace(80)

        let labelX = c.pageW - c.margin - 240
        let valX   = c.pageW - c.margin - 100
        let labelW: CGFloat = 130
        let valW:   CGFloat = 100

        c.posY += 6
        c.put("Subtotal", font: c.fVal, color: c.clrMid,
              x: labelX, y: c.posY, w: labelW, h: 14, align: .right)
        c.put(sale.subtotal.currencyString, font: c.fVal, color: c.clrDark,
              x: valX, y: c.posY, w: valW, h: 14, align: .right)
        c.posY += 16

        if sale.taxRate > 0 {
            let taxRateInt = NSDecimalNumber(decimal: sale.taxRate).intValue
            let taxLabel = "Tax (\(taxRateInt)%)"
            c.put(taxLabel, font: c.fVal, color: c.clrMid,
                  x: labelX, y: c.posY, w: labelW, h: 14, align: .right)
            c.put(sale.taxAmount.currencyString, font: c.fVal, color: c.clrDark,
                  x: valX, y: c.posY, w: valW, h: 14, align: .right)
            c.posY += 16
        }

        // Bold total
        c.posY += 4
        c.put("TOTAL", font: c.fHdr, color: c.clrBlue,
              x: labelX, y: c.posY, w: labelW, h: 16, align: .right)
        c.put(sale.grandTotal.currencyString, font: c.fHdr, color: c.clrBlue,
              x: valX, y: c.posY, w: valW, h: 16, align: .right)
        c.posY += 22
    }

    // MARK: Notes

    private func drawNotes(_ text: String) {
        c.ensureSpace(40)
        c.posY += 4
        c.put("NOTES", font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: c.cW, h: 13)
        c.posY += 16
        let bodyH = c.textH(text, width: c.cW, font: c.fVal)
        c.putWrap(text, font: c.fVal, color: c.clrDark,
                  x: c.margin, y: c.posY, w: c.cW, h: bodyH + 4)
        c.posY += bodyH + 8
    }

    // MARK: T&C

    /// Same shape as QuotePDFRenderer / EstimatePDFRenderer drawTermsAndConditions —
    /// kept consistent so all three documents present T&C identically.
    private func drawTermsAndConditions() {
        c.ensureSpace(40)
        c.posY += 4
        c.put("TERMS & CONDITIONS",
              font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: c.cW, h: 13)
        c.posY += 18

        let titleFont = UIFont.systemFont(ofSize: 11, weight: .bold)
        let versionFont = UIFont.systemFont(ofSize: 8.5, weight: .regular)

        let sorted = saleTerms.sorted(by: { $0.displayOrder < $1.displayOrder })
        for (idx, term) in sorted.enumerated() {
            let bodyH = c.textH(term.bodySnapshot, width: c.cW, font: c.fVal)
            let blockH = 18 + bodyH + 14
            if c.posY + 18 > c.pageH - c.margin - 12 {
                c.ensureSpace(blockH)
            }

            c.put(term.titleSnapshot,
                  font: titleFont, color: c.clrDark,
                  x: c.margin, y: c.posY, w: c.cW - 60, h: 16)

            if term.isCustom {
                c.put("CUSTOM",
                      font: versionFont, color: c.clrMid,
                      x: c.margin, y: c.posY, w: c.cW, h: 16, align: .right)
            } else if let v = term.versionSnapshot {
                c.put("v\(v)",
                      font: versionFont, color: c.clrMid,
                      x: c.margin, y: c.posY, w: c.cW, h: 16, align: .right)
            }
            c.posY += 18

            c.putWrap(term.bodySnapshot,
                      font: c.fVal, color: c.clrDark,
                      x: c.margin, y: c.posY, w: c.cW, h: bodyH + 4)
            c.posY += bodyH + 8

            if idx < sorted.count - 1 {
                c.clrLight.setStroke()
                let sep = UIBezierPath()
                sep.move(to:    CGPoint(x: c.margin,        y: c.posY))
                sep.addLine(to: CGPoint(x: c.pageW - c.margin, y: c.posY))
                sep.lineWidth = 0.4
                sep.stroke()
                c.posY += 8
            }
        }
        c.posY += 6
    }

    // MARK: Footer

    private func drawFooter() {
        let now = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        c.put("Generated: \(now)  ·  Aski IQ",
              font: c.fCap, color: c.clrMid,
              x: c.margin, y: c.posY + 4, w: c.cW, h: 12)
    }
}

// MARK: - Invoice PDF Renderer
// Professional client-facing invoice: header, bill-to block, line items table, totals, payment info.

final class InvoicePDFRenderer {

    private let invoice: Invoice
    private let c = PDFCanvas()

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    init(invoice: Invoice) {
        self.invoice = invoice
    }

    // MARK: Public entry point

    func render() -> Data {
        let bounds = CGRect(x: 0, y: 0, width: c.pageW, height: c.pageH)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            c.ctx = ctx
            ctx.beginPage()
            c.posY = c.margin

            drawHeader()
            c.hr(thick: true, color: c.clrBlue)
            drawBillToBlock()
            c.hr(thick: false, color: c.clrLight)
            drawLineItemsTable()
            c.hr(thick: false, color: c.clrLight)
            drawTotals()
            if !invoice.notes.isEmpty {
                c.hr(thick: false, color: c.clrLight)
                drawNotes()
            }
            c.hr(thick: true, color: c.clrBlue)
            drawFooter()
        }
    }

    // MARK: Header

    private func drawHeader() {
        let settings = AppSettings.shared
        let prefix   = settings.companyPrefix.isEmpty ? "BV" : settings.companyPrefix
        let company  = settings.companyName.isEmpty   ? "Aski IQ" : settings.companyName

        // Company name
        c.put(company,
              font: c.fCo, color: c.clrBlue,
              x: c.margin, y: c.posY, w: 260, h: 24)

        // INVOICE badge
        c.drawBadge("INVOICE", color: c.clrBlue,
                    rightX: c.pageW - c.margin, topY: c.posY)

        c.posY += 28

        // Invoice number + date block
        c.put(invoice.invoiceNumber,
              font: c.fHdr, color: c.clrDark,
              x: c.margin, y: c.posY, w: 200, h: 14)

        let invDateStr = "Invoice Date: \(dateFormatter.string(from: invoice.invoiceDate))"
        let dueDateStr = "Due: \(dateFormatter.string(from: invoice.dueDate))"

        c.put(invDateStr, font: c.fVal, color: c.clrMid,
              x: c.pageW - c.margin - 260, y: c.posY, w: 260, h: 14, align: .right)
        c.posY += 14
        c.put(dueDateStr, font: c.fVal, color: invoice.isOverdue ? .systemRed : c.clrMid,
              x: c.pageW - c.margin - 260, y: c.posY, w: 260, h: 14, align: .right)

        // Terms + PO
        if !invoice.terms.isEmpty {
            c.put("Terms: \(invoice.terms)", font: c.fVal, color: c.clrMid,
                  x: c.margin, y: c.posY, w: 200, h: 14)
        }
        c.posY += 18

        if !invoice.poNumber.isEmpty {
            c.put("Client PO: \(invoice.poNumber)", font: c.fVal, color: c.clrMid,
                  x: c.margin, y: c.posY, w: 200, h: 12)
            c.posY += 14
        }

        c.posY += 4
    }

    // MARK: Bill To Block

    private func drawBillToBlock() {
        c.put("BILL TO", font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: 80, h: 12)
        c.posY += 14

        if !invoice.billToName.isEmpty {
            c.put(invoice.billToName, font: c.fHdr, color: c.clrDark,
                  x: c.margin, y: c.posY, w: 300, h: 14)
            c.posY += 14
        }

        if !invoice.billToAddress.isEmpty {
            let addrLines = invoice.billToAddress.components(separatedBy: "\n")
            for line in addrLines where !line.isEmpty {
                c.put(line, font: c.fVal, color: c.clrMid,
                      x: c.margin, y: c.posY, w: 300, h: 12)
                c.posY += 13
            }
        }

        c.posY += 6
    }

    // MARK: Line Items Table

    private func drawLineItemsTable() {
        c.put("LINE ITEMS", font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: 120, h: 12)
        c.posY += 14

        // Column widths
        let descW:  CGFloat = c.cW - 60 - 60 - 80   // description
        let qtyW:   CGFloat = 60
        let priceW: CGFloat = 60
        let amtW:   CGFloat = 80

        let col0 = c.margin
        let col1 = col0 + descW
        let col2 = col1 + qtyW
        let col3 = col2 + priceW

        // Header row background
        UIColor(white: 0.94, alpha: 1).setFill()
        UIBezierPath(rect: CGRect(x: c.margin, y: c.posY, width: c.cW, height: 16)).fill()

        c.put("DESCRIPTION", font: c.fSec, color: c.clrMid, x: col0 + 4, y: c.posY + 2, w: descW - 4, h: 12)
        c.put("QTY",         font: c.fSec, color: c.clrMid, x: col1,     y: c.posY + 2, w: qtyW - 4,  h: 12, align: .right)
        c.put("UNIT",        font: c.fSec, color: c.clrMid, x: col2,     y: c.posY + 2, w: priceW - 4, h: 12, align: .right)
        c.put("AMOUNT",      font: c.fSec, color: c.clrMid, x: col3,     y: c.posY + 2, w: amtW - 4,  h: 12, align: .right)
        c.posY += 18

        // Rows
        for (i, item) in invoice.lineItems.enumerated() {
            c.ensureSpace(20)

            let bg = i % 2 == 0 ? UIColor.white : UIColor(white: 0.97, alpha: 1)
            bg.setFill()
            UIBezierPath(rect: CGRect(x: c.margin, y: c.posY, width: c.cW, height: 18)).fill()

            let descH = max(14, c.textH(item.description, width: descW - 8, font: c.fVal))
            c.putWrap(item.description, font: c.fVal, color: c.clrDark,
                      x: col0 + 4, y: c.posY + 2, w: descW - 8, h: descH)

            c.put(decStr(item.quantity),           font: c.fVal, color: c.clrDark,
                  x: col1, y: c.posY + 2, w: qtyW - 4,   h: 14, align: .right)
            c.put(currStr(item.unitPrice),         font: c.fVal, color: c.clrDark,
                  x: col2, y: c.posY + 2, w: priceW - 4, h: 14, align: .right)
            c.put(currStr(item.subtotal),          font: c.fMon, color: c.clrDark,
                  x: col3, y: c.posY + 2, w: amtW - 4,   h: 14, align: .right)

            c.posY += max(18, descH + 4)
        }
    }

    // MARK: Totals

    private func drawTotals() {
        c.ensureSpace(80)

        let labelW: CGFloat = 100
        let valueW: CGFloat = 90
        let rightX  = c.pageW - c.margin - valueW - labelW

        func row(_ label: String, _ value: String, bold: Bool = false, color: UIColor? = nil) {
            let font  = bold ? c.fHdr : c.fVal
            let clr   = color ?? (bold ? c.clrDark : c.clrMid)
            c.put(label, font: c.fVal, color: c.clrMid,
                  x: rightX, y: c.posY, w: labelW - 4, h: 14, align: .right)
            c.put(value, font: font,   color: clr,
                  x: rightX + labelW, y: c.posY, w: valueW - 4, h: 14, align: .right)
            c.posY += 16
        }

        row("Subtotal:", currStr(invoice.subtotal))
        if invoice.taxAmount > 0 {
            let pct = Int(NSDecimalNumber(decimal: invoice.taxRate * 100).intValue)
            row("GST (\(pct)%):", currStr(invoice.taxAmount))
        }

        // Divider before total
        let divX = rightX + 20
        UIColor(white: 0.80, alpha: 1).setStroke()
        let path = UIBezierPath()
        path.move(to:    CGPoint(x: divX, y: c.posY))
        path.addLine(to: CGPoint(x: c.pageW - c.margin, y: c.posY))
        path.lineWidth = 0.5
        path.stroke()
        c.posY += 4

        row("TOTAL:", currStr(invoice.total), bold: true)

        if invoice.totalPaid > 0 {
            row("Paid:", "- \(currStr(invoice.totalPaid))", color: c.clrGreen)
        }

        if invoice.balanceDue != invoice.total || invoice.totalPaid > 0 {
            let dueColor = invoice.balanceDue > 0 ? UIColor.systemOrange : c.clrGreen
            row("BALANCE DUE:", currStr(invoice.balanceDue), bold: true, color: dueColor)
        }

        c.posY += 4
    }

    // MARK: Notes

    private func drawNotes() {
        c.put("NOTES", font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: 120, h: 12)
        c.posY += 14
        let h = c.textH(invoice.notes, width: c.cW, font: c.fVal)
        c.putWrap(invoice.notes, font: c.fVal, color: c.clrMid,
                  x: c.margin, y: c.posY, w: c.cW, h: h)
        c.posY += h + 8
    }

    // MARK: Footer

    private func drawFooter() {
        let now = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        c.put("Generated: \(now)  ·  Aski IQ  ·  \(invoice.invoiceNumber)",
              font: c.fCap, color: c.clrMid,
              x: c.margin, y: c.posY + 4, w: c.cW, h: 12)
    }

    // MARK: Helpers

    private func decStr(_ d: Decimal) -> String {
        let n = NSDecimalNumber(decimal: d)
        if d == Decimal(Int(truncating: n)) { return "\(Int(truncating: n))" }
        return n.stringValue
    }

    private func currStr(_ d: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "CAD"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: d)) ?? "$\(d)"
    }
}

// MARK: - Change Order PDF Renderer
// Professional CO document: header, project block, CO details, optional line items, financial summary.

final class ChangeOrderPDFRenderer {

    private let co:          ChangeOrder
    private let projectName: String?
    private let companyName: String
    private let c = PDFCanvas()

    private let df: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    init(changeOrder co: ChangeOrder, projectName: String?, companyName: String) {
        self.co          = co
        self.projectName = projectName
        self.companyName = companyName
    }

    func render() -> Data {
        let bounds = CGRect(x: 0, y: 0, width: c.pageW, height: c.pageH)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            c.ctx = ctx
            ctx.beginPage()
            c.posY = c.margin

            drawHeader()
            c.hr(thick: true, color: c.clrBlue)
            drawMetaBlock()
            c.hr(thick: false, color: c.clrLight)

            if !co.description.isEmpty { drawTextSection("DESCRIPTION",        text: co.description) }
            if let reason = co.reason, !reason.isEmpty { drawTextSection("REASON / JUSTIFICATION", text: reason) }
            if !co.lineItems.isEmpty { drawLineItemsTable() }

            drawImpactBlock()

            if let notes = co.notes, !notes.isEmpty {
                c.hr(thick: false, color: c.clrLight)
                drawTextSection("NOTES", text: notes)
            }

            c.hr(thick: true, color: c.clrBlue)
            drawFooter()
        }
    }

    // MARK: Header

    private func drawHeader() {
        let company = companyName.isEmpty ? "BLAIR VENTURES" : companyName.uppercased()
        c.put(company, font: c.fCo, color: c.clrBlue,
              x: c.margin, y: c.posY, w: c.cW - 130, h: 26)

        // Status badge colour
        let badgeColor: UIColor
        switch co.status {
        case .approved:    badgeColor = .systemGreen
        case .rejected:    badgeColor = .systemRed
        case .underReview: badgeColor = .systemOrange
        case .submitted:   badgeColor = .systemBlue
        case .voided:      badgeColor = .systemGray
        case .draft:       badgeColor = .systemGray
        }
        c.drawBadge("CHANGE ORDER", color: c.clrBlue,
                    rightX: c.pageW - c.margin, topY: c.posY + 4)
        c.posY += 30

        // CO number
        c.put(co.number, font: c.fMon, color: c.clrDark,
              x: c.margin, y: c.posY, w: c.cW - 130, h: 14)

        // Status badge right-aligned
        c.drawBadge(co.status.displayName.uppercased(), color: badgeColor,
                    rightX: c.pageW - c.margin, topY: c.posY)
        c.posY += 18

        c.put(co.title,
              font: UIFont.systemFont(ofSize: 12, weight: .semibold), color: c.clrDark,
              x: c.margin, y: c.posY, w: c.cW, h: 16)
        c.posY += 20
    }

    // MARK: Meta Block

    private func drawMetaBlock() {
        let col1W: CGFloat = c.cW * 0.52
        let col2X  = c.margin + col1W + 16
        let col2W  = c.cW - col1W - 16
        let startY = c.posY

        // Left: project + type
        let leftPairs: [(String, String)] = [
            ("Project",    projectName ?? "—"),
            ("Type",       co.type.displayName),
            ("Client Ref", co.clientReferenceNumber ?? "—"),
        ]
        var leftY = startY
        for (lbl, val) in leftPairs {
            c.put(lbl + ":", font: c.fLbl, color: c.clrMid,
                  x: c.margin, y: leftY, w: 80, h: 14)
            c.put(val, font: c.fVal, color: c.clrDark,
                  x: c.margin + 82, y: leftY, w: col1W - 82, h: 14)
            leftY += 15
        }

        // Right: dates
        var rightPairs: [(String, String)] = [
            ("Created", df.string(from: co.createdAt)),
        ]
        if let sub = co.submittedDate { rightPairs.append(("Submitted", df.string(from: sub))) }
        if let app = co.approvedDate  { rightPairs.append(("Approved",  df.string(from: app))) }
        if let rej = co.rejectedDate  { rightPairs.append(("Rejected",  df.string(from: rej))) }
        if let by  = co.approvedByName { rightPairs.append(("Approved By", by)) }

        var rightY = startY
        for (lbl, val) in rightPairs {
            c.put(lbl + ":", font: c.fLbl, color: c.clrMid,
                  x: col2X, y: rightY, w: 80, h: 14)
            c.put(val, font: c.fVal, color: c.clrDark,
                  x: col2X + 82, y: rightY, w: col2W - 82, h: 14)
            rightY += 15
        }

        c.posY = max(leftY, rightY) + 8
    }

    // MARK: Text Section

    private func drawTextSection(_ heading: String, text: String) {
        guard !text.isEmpty else { return }
        let h = c.textH(text, width: c.cW, font: c.fVal)
        c.ensureSpace(16 + h + 14)
        c.posY += 6
        c.put(heading, font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: c.cW, h: 13)
        c.posY += 16
        c.putWrap(text, font: c.fVal, color: c.clrDark,
                  x: c.margin, y: c.posY, w: c.cW, h: h + 4)
        c.posY += h + 10
    }

    // MARK: Line Items Table

    private func drawLineItemsTable() {
        c.ensureSpace(50)
        c.posY += 6
        c.put("LINE ITEMS", font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: c.cW, h: 13)
        c.posY += 16

        let descW: CGFloat = c.cW * 0.50
        let unitW: CGFloat = c.cW * 0.10
        let qtyW:  CGFloat = c.cW * 0.10
        let rateW: CGFloat = c.cW * 0.15
        let amtW:  CGFloat = c.cW - descW - unitW - qtyW - rateW
        let col2 = c.margin + descW
        let col3 = col2 + unitW
        let col4 = col3 + qtyW
        let col5 = col4 + rateW

        // Header
        c.clrBlue.withAlphaComponent(0.09).setFill()
        UIRectFill(CGRect(x: c.margin, y: c.posY, width: c.cW, height: 18))
        let cols: [(String, CGFloat, CGFloat, NSTextAlignment)] = [
            ("Description", c.margin, descW, .left),
            ("Unit",        col2,     unitW, .center),
            ("Qty",         col3,     qtyW,  .right),
            ("Unit Price",  col4,     rateW, .right),
            ("Total",       col5,     amtW,  .right),
        ]
        for (t, x, w, a) in cols {
            c.put(t, font: c.fLbl, color: c.clrBlue, x: x + 3, y: c.posY + 3, w: w - 6, h: 13, align: a)
        }
        c.posY += 20

        for (i, item) in co.lineItems.enumerated() {
            let descH = max(14, c.textH(item.description, width: descW - 8, font: c.fVal))
            let rowH  = descH + 10
            c.ensureSpace(rowH + 4)

            if i % 2 == 0 {
                UIColor(white: 0.97, alpha: 1).setFill()
                UIRectFill(CGRect(x: c.margin, y: c.posY, width: c.cW, height: rowH))
            }
            c.putWrap(item.description, font: c.fVal, color: c.clrDark,
                      x: c.margin + 3, y: c.posY + 3, w: descW - 8, h: descH)
            func rCell(_ t: String, x: CGFloat, w: CGFloat) {
                c.put(t, font: c.fVal, color: c.clrDark, x: x + 2, y: c.posY + 3, w: w - 5, h: 14, align: .right)
            }
            rCell(item.unit,                   x: col2, w: unitW)
            rCell(decStr(item.quantity),        x: col3, w: qtyW)
            rCell(currStr(item.unitPrice),      x: col4, w: rateW)
            rCell(currStr(item.total),          x: col5, w: amtW)
            c.posY += rowH
        }
        c.posY += 8
    }

    // MARK: Impact Block

    private func drawImpactBlock() {
        let effectiveCost = co.effectiveCostImpact
        let rightW: CGFloat = 220
        let labelW: CGFloat = 130
        let valueW  = rightW - labelW
        let rightX  = c.pageW - c.margin - rightW

        var rows: [(String, String, Bool, UIColor?)] = [
            ("Cost Impact", currStr(effectiveCost), true, effectiveCost >= 0 ? c.clrGreen : .systemRed),
        ]
        if co.scheduleImpactDays != 0 {
            let days = co.scheduleImpactDays
            let txt  = "\(days > 0 ? "+" : "")\(days) calendar days"
            rows.append(("Schedule Impact", txt, false, days > 0 ? .systemOrange : c.clrGreen))
        }

        let rowH: CGFloat = 22
        c.ensureSpace(CGFloat(rows.count) * rowH + 20)
        c.posY += 10

        for (label, value, bold, color) in rows {
            if bold {
                c.clrBlue.withAlphaComponent(0.08).setFill()
                UIRectFill(CGRect(x: rightX - 8, y: c.posY, width: rightW + 8, height: rowH))
            }
            let font  = bold ? UIFont.systemFont(ofSize: 10, weight: .bold)
                             : UIFont.systemFont(ofSize: 9.5, weight: .regular)
            c.put(label, font: c.fLbl, color: c.clrMid,
                  x: rightX, y: c.posY + 3, w: labelW, h: 14, align: .right)
            c.put(value, font: font, color: color ?? c.clrDark,
                  x: rightX + labelW + 4, y: c.posY + 3, w: valueW - 4, h: 14, align: .right)
            c.posY += rowH
        }
        c.posY += 6
    }

    // MARK: Footer

    private func drawFooter() {
        let now = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        c.put("Generated: \(now)  ·  Aski IQ  ·  \(co.number)",
              font: c.fCap, color: c.clrMid,
              x: c.margin, y: c.posY + 4, w: c.cW, h: 12)
    }

    // MARK: Helpers

    private func decStr(_ d: Decimal) -> String {
        let n = NSDecimalNumber(decimal: d)
        if d == Decimal(Int(truncating: n)) { return "\(Int(truncating: n))" }
        return n.stringValue
    }

    private func currStr(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency; f.currencyCode = "CAD"
        f.maximumFractionDigits = 2; f.minimumFractionDigits = 2
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "$\(d)"
    }
}

// MARK: - Sub-Contract PDF Renderer
// Internal/client-facing contract summary: header, parties block, financial summary, scope, terms.

final class SubContractPDFRenderer {

    private let sc:             SubContract
    private let subName:        String
    private let projectName:    String?
    private let companyName:    String
    private let c = PDFCanvas()

    private let df: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    init(subContract: SubContract, subcontractorName: String, projectName: String?, companyName: String) {
        self.sc          = subContract
        self.subName     = subcontractorName
        self.projectName = projectName
        self.companyName = companyName
    }

    func render() -> Data {
        let bounds = CGRect(x: 0, y: 0, width: c.pageW, height: c.pageH)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            c.ctx = ctx
            ctx.beginPage()
            c.posY = c.margin

            drawHeader()
            c.hr(thick: true, color: c.clrBlue)
            drawPartiesBlock()
            c.hr(thick: false, color: c.clrLight)

            if !sc.scope.isEmpty { drawTextSection("SCOPE OF WORK", text: sc.scope) }

            drawFinancialSummary()

            if let terms = sc.paymentTerms, !terms.isEmpty {
                c.hr(thick: false, color: c.clrLight)
                drawTextSection("PAYMENT TERMS", text: terms)
            }
            if let notes = sc.notes, !notes.isEmpty {
                c.hr(thick: false, color: c.clrLight)
                drawTextSection("NOTES", text: notes)
            }

            c.hr(thick: true, color: c.clrBlue)
            drawFooter()
        }
    }

    // MARK: Header

    private func drawHeader() {
        let company = companyName.isEmpty ? "BLAIR VENTURES" : companyName.uppercased()
        c.put(company, font: c.fCo, color: c.clrBlue,
              x: c.margin, y: c.posY, w: c.cW - 130, h: 26)

        let badgeColor: UIColor
        switch sc.status {
        case .inProgress: badgeColor = .systemGreen
        case .executed:   badgeColor = .systemBlue
        case .complete:   badgeColor = .systemTeal
        case .disputed:   badgeColor = .systemRed
        case .terminated: badgeColor = .systemGray
        case .draft:      badgeColor = .systemGray
        }
        c.drawBadge("SUB-CONTRACT", color: c.clrBlue,
                    rightX: c.pageW - c.margin, topY: c.posY + 4)
        c.posY += 30

        c.put(sc.contractNumber, font: c.fMon, color: c.clrDark,
              x: c.margin, y: c.posY, w: c.cW - 130, h: 14)
        c.drawBadge(sc.status.displayName.uppercased(), color: badgeColor,
                    rightX: c.pageW - c.margin, topY: c.posY)
        c.posY += 20
    }

    // MARK: Parties Block

    private func drawPartiesBlock() {
        let col1W: CGFloat = (c.cW - 20) / 2
        let col2X  = c.margin + col1W + 20
        let startY = c.posY

        // Left — General Contractor (us)
        c.put("GENERAL CONTRACTOR:", font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: col1W, h: 13)
        var leftY = startY + 16
        c.put(companyName.isEmpty ? "Aski IQ" : companyName,
              font: UIFont.systemFont(ofSize: 10.5, weight: .semibold), color: c.clrDark,
              x: c.margin, y: leftY, w: col1W, h: 14)
        leftY += 16

        if let proj = projectName {
            c.put("Project: \(proj)", font: c.fVal, color: c.clrMid,
                  x: c.margin, y: leftY, w: col1W, h: 14)
            leftY += 14
        }

        // Right — Subcontractor
        c.put("SUBCONTRACTOR:", font: c.fSec, color: c.clrBlue,
              x: col2X, y: startY, w: col1W, h: 13)
        var rightY = startY + 16
        c.put(subName,
              font: UIFont.systemFont(ofSize: 10.5, weight: .semibold), color: c.clrDark,
              x: col2X, y: rightY, w: col1W, h: 14)
        rightY += 16

        // Schedule dates
        let datePairs: [(String, Date?)] = [
            ("Start Date",    sc.startDate),
            ("End Date",      sc.endDate),
            ("Executed",      sc.executedDate),
        ]
        for (lbl, date) in datePairs {
            if let d = date {
                c.put(lbl + ":", font: c.fLbl, color: c.clrMid,
                      x: col2X, y: rightY, w: 70, h: 14)
                c.put(df.string(from: d), font: c.fVal, color: c.clrDark,
                      x: col2X + 72, y: rightY, w: col1W - 72, h: 14)
                rightY += 15
            }
        }

        c.posY = max(leftY, rightY) + 10
    }

    // MARK: Text Section

    private func drawTextSection(_ heading: String, text: String) {
        guard !text.isEmpty else { return }
        let h = c.textH(text, width: c.cW, font: c.fVal)
        c.ensureSpace(16 + h + 14)
        c.posY += 6
        c.put(heading, font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: c.cW, h: 13)
        c.posY += 16
        c.putWrap(text, font: c.fVal, color: c.clrDark,
                  x: c.margin, y: c.posY, w: c.cW, h: h + 4)
        c.posY += h + 10
    }

    // MARK: Financial Summary

    private func drawFinancialSummary() {
        let rightW: CGFloat = 240
        let labelW: CGFloat = 140
        let valueW  = rightW - labelW
        let rightX  = c.pageW - c.margin - rightW

        let retention = sc.retentionAmount
        let netPay    = sc.netPayable

        let rows: [(String, String, Bool, UIColor?)] = [
            ("Contract Value",     currStr(sc.contractValue),    false, nil),
            ("Invoiced to Date",   currStr(sc.invoicedToDate),   false, nil),
            ("Retention (\(retPct())%)", currStr(retention),     false, .systemOrange),
            ("Paid to Date",       "- \(currStr(sc.paidToDate))", false, c.clrGreen),
            ("NET PAYABLE",        currStr(netPay),              true,  netPay > 0 ? .systemOrange : c.clrGreen),
        ]

        let rowH: CGFloat = 22
        c.ensureSpace(CGFloat(rows.count) * rowH + 24)
        c.posY += 10

        c.put("FINANCIAL SUMMARY", font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: c.cW, h: 13)
        c.posY += 18

        for (label, value, bold, color) in rows {
            if bold {
                c.clrBlue.withAlphaComponent(0.08).setFill()
                UIRectFill(CGRect(x: rightX - 8, y: c.posY, width: rightW + 8, height: rowH))
            }
            let font  = bold ? UIFont.systemFont(ofSize: 10, weight: .bold)
                             : UIFont.systemFont(ofSize: 9.5, weight: .regular)
            c.put(label, font: c.fLbl, color: c.clrMid,
                  x: rightX, y: c.posY + 3, w: labelW, h: 14, align: .right)
            c.put(value, font: font, color: color ?? c.clrDark,
                  x: rightX + labelW + 4, y: c.posY + 3, w: valueW - 4, h: 14, align: .right)
            c.posY += rowH
        }
        c.posY += 6
    }

    // MARK: Footer

    private func drawFooter() {
        let now = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        c.put("Generated: \(now)  ·  Aski IQ  ·  \(sc.contractNumber)",
              font: c.fCap, color: c.clrMid,
              x: c.margin, y: c.posY + 4, w: c.cW, h: 12)
    }

    // MARK: Helpers

    private func retPct() -> String {
        let n = NSDecimalNumber(decimal: sc.retentionPercent)
        if sc.retentionPercent == Decimal(Int(truncating: n)) { return "\(Int(truncating: n))" }
        return n.stringValue
    }

    private func currStr(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency; f.currencyCode = "CAD"
        f.maximumFractionDigits = 2; f.minimumFractionDigits = 2
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "$\(d)"
    }
}

// MARK: - Material Request PDF Renderer
// Internal-facing approval document. Generated on approval and attached to
// the destination's document grid (project / material sale) so the audit
// record of what was approved is immutable and shareable.

final class MaterialRequestPDFRenderer {

    private let mr:                MaterialRequest
    private let destinationName:   String?
    private let supplierName:      String?
    private let approvedBy:        String?
    private let c = PDFCanvas()

    private let df: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    init(mr: MaterialRequest,
         destinationName: String?,
         supplierName: String?,
         approvedBy: String?) {
        self.mr               = mr
        self.destinationName  = destinationName
        self.supplierName     = supplierName
        self.approvedBy       = approvedBy
    }

    func render() -> Data {
        let bounds = CGRect(x: 0, y: 0, width: c.pageW, height: c.pageH)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            c.ctx = ctx
            ctx.beginPage()
            c.posY = c.margin

            drawHeader()
            c.hr(thick: true, color: c.clrBlue)
            drawDetailsBlock()
            c.hr(thick: false, color: c.clrLight)
            if !mr.lineItems.isEmpty {
                drawLineItemsTable()
                c.hr(thick: false, color: c.clrLight)
                drawTotal()
            }
            if !mr.notes.isEmpty {
                c.hr(thick: false, color: c.clrLight)
                drawTextSection("NOTES", text: mr.notes)
            }
            if mr.status == .approved || mr.approvedAt != nil {
                c.hr(thick: false, color: c.clrLight)
                drawApprovalBlock()
            }
            c.hr(thick: true, color: c.clrBlue)
            drawFooter()
        }
    }

    private func drawHeader() {
        let settings = AppSettings.shared
        let companyName = settings.companyName.isEmpty ? "BLAIR VENTURES" : settings.companyName.uppercased()

        let logoSize: CGFloat = 50
        var nameX = c.margin
        if let logo = UIImage(named: "AskiIQPrimaryLogo") {
            let rect = CGRect(x: c.margin, y: c.posY - 4, width: logoSize, height: logoSize)
            logo.draw(in: rect)
            nameX = c.margin + logoSize + 12
        }

        c.put(companyName, font: c.fCo, color: c.clrBlue,
              x: nameX, y: c.posY, w: c.cW - 110 - (nameX - c.margin), h: 26)
        c.drawBadge("MATERIAL REQUEST", color: c.clrBlue,
                    rightX: c.pageW - c.margin, topY: c.posY + 4)
        c.posY += 30
        c.put(mr.requestNumber, font: c.fMon, color: c.clrDark,
              x: nameX, y: c.posY, w: c.cW - (nameX - c.margin), h: 14)
        c.posY += 16
        var parts: [String] = []
        if !settings.companyAddress.isEmpty { parts.append(settings.companyAddress) }
        if !settings.companyPhone.isEmpty   { parts.append(settings.companyPhone)   }
        if !settings.companyEmail.isEmpty   { parts.append(settings.companyEmail)   }
        if !parts.isEmpty {
            c.put(parts.joined(separator: "  |  "), font: c.fCap, color: c.clrMid,
                  x: nameX, y: c.posY, w: c.cW - (nameX - c.margin), h: 12)
            c.posY += 14
        }
        if c.posY < logoSize + 4 { c.posY = logoSize + 4 }
        c.posY += 4
    }

    private func drawDetailsBlock() {
        let col1W: CGFloat = c.cW * 0.54
        let col2X = c.margin + col1W + 20
        let col2W = c.cW - col1W - 20
        let startY = c.posY

        c.put("REQUESTED BY", font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: col1W, h: 13)
        c.posY += 16
        if !mr.requestedByName.isEmpty {
            c.put(mr.requestedByName,
                  font: UIFont.systemFont(ofSize: 10.5, weight: .semibold), color: c.clrDark,
                  x: c.margin, y: c.posY, w: col1W, h: 14)
            c.posY += 16
        }

        c.put("DESTINATION", font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: col1W, h: 13)
        c.posY += 16
        let destLine: String = {
            switch mr.destinationType {
            case .project:      return "Project: \(destinationName ?? "—")"
            case .materialSale: return "Material Sale: \(destinationName ?? "—")"
            case .internalUse:  return "Internal / Yard"
            }
        }()
        c.put(destLine, font: c.fVal, color: c.clrDark,
              x: c.margin, y: c.posY, w: col1W, h: 14)
        c.posY += 16
        if !mr.siteLocation.isEmpty {
            c.put("Site Location: \(mr.siteLocation)",
                  font: c.fVal, color: c.clrMid,
                  x: c.margin, y: c.posY, w: col1W, h: 14)
            c.posY += 14
        }
        if let supplier = supplierName, !supplier.isEmpty {
            c.put("Preferred Supplier: \(supplier)",
                  font: c.fVal, color: c.clrMid,
                  x: c.margin, y: c.posY, w: col1W, h: 14)
            c.posY += 14
        }

        var pairs: [(String, String)] = [
            ("Request Date", df.string(from: mr.requestDate)),
        ]
        if let req = mr.requiredByDate {
            pairs.append(("Required By", df.string(from: req)))
        }
        if let sub = mr.submittedAt {
            pairs.append(("Submitted",   df.string(from: sub)))
        }
        pairs.append(("Status", mr.status.displayName))

        var rightY = startY
        for (lbl, val) in pairs {
            c.put(lbl + ":", font: c.fLbl, color: c.clrMid,
                  x: col2X, y: rightY, w: 90, h: 14)
            c.put(val, font: c.fVal, color: c.clrDark,
                  x: col2X + 92, y: rightY, w: col2W - 92, h: 14)
            rightY += 16
        }
        c.posY = max(c.posY, rightY) + 8
    }

    private func drawLineItemsTable() {
        c.ensureSpace(50)
        c.put("MATERIALS REQUESTED", font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: 200, h: 12)
        c.posY += 14

        let descW: CGFloat = c.cW * 0.50
        let unitW: CGFloat = c.cW * 0.10
        let qtyW:  CGFloat = c.cW * 0.12
        let costW: CGFloat = c.cW * 0.14
        let amtW:  CGFloat = c.cW - descW - unitW - qtyW - costW
        let col2 = c.margin + descW
        let col3 = col2 + unitW
        let col4 = col3 + qtyW
        let col5 = col4 + costW

        UIColor(white: 0.94, alpha: 1).setFill()
        UIBezierPath(rect: CGRect(x: c.margin, y: c.posY, width: c.cW, height: 16)).fill()

        c.put("DESCRIPTION", font: c.fSec, color: c.clrMid,
              x: c.margin + 4, y: c.posY + 2, w: descW - 6, h: 12)
        c.put("UNIT", font: c.fSec, color: c.clrMid,
              x: col2, y: c.posY + 2, w: unitW - 4, h: 12, align: .center)
        c.put("QTY", font: c.fSec, color: c.clrMid,
              x: col3, y: c.posY + 2, w: qtyW - 4, h: 12, align: .right)
        c.put("EST. COST", font: c.fSec, color: c.clrMid,
              x: col4, y: c.posY + 2, w: costW - 4, h: 12, align: .right)
        c.put("AMOUNT", font: c.fSec, color: c.clrMid,
              x: col5, y: c.posY + 2, w: amtW - 4, h: 12, align: .right)
        c.posY += 18

        for (i, item) in mr.lineItems.enumerated() {
            let descText = item.costCode.isEmpty
                ? item.description
                : "[\(item.costCode)]  \(item.description)"
            let descH = max(14, c.textH(descText, width: descW - 8, font: c.fVal))
            let rowH  = descH + 6
            c.ensureSpace(rowH + 4)

            let bg = i % 2 == 0 ? UIColor.white : UIColor(white: 0.97, alpha: 1)
            bg.setFill()
            UIBezierPath(rect: CGRect(x: c.margin, y: c.posY, width: c.cW, height: rowH)).fill()

            c.putWrap(descText, font: c.fVal, color: c.clrDark,
                      x: c.margin + 4, y: c.posY + 2, w: descW - 8, h: descH)
            c.put(item.unit.displayName, font: c.fVal, color: c.clrDark,
                  x: col2, y: c.posY + 2, w: unitW - 4, h: 14, align: .center)
            c.put(decStr(item.quantity), font: c.fVal, color: c.clrDark,
                  x: col3, y: c.posY + 2, w: qtyW - 4, h: 14, align: .right)
            c.put(item.unitCost > 0 ? currStr(item.unitCost) : "—",
                  font: c.fVal, color: c.clrDark,
                  x: col4, y: c.posY + 2, w: costW - 4, h: 14, align: .right)
            c.put(item.totalCost > 0 ? currStr(item.totalCost) : "—",
                  font: c.fMon, color: c.clrDark,
                  x: col5, y: c.posY + 2, w: amtW - 4, h: 14, align: .right)
            c.posY += rowH
        }
    }

    private func drawTotal() {
        c.ensureSpace(40)
        let total = mr.lineItems.reduce(Decimal(0)) { $0 + $1.totalCost }
        guard total > 0 else { return }
        let labelW: CGFloat = 140
        let valueW: CGFloat = 100
        let rightX  = c.pageW - c.margin - valueW - labelW
        c.put("ESTIMATED TOTAL", font: c.fHdr, color: c.clrDark,
              x: rightX, y: c.posY, w: labelW - 4, h: 14, align: .right)
        c.put(currStr(total), font: c.fHdr, color: c.clrDark,
              x: rightX + labelW, y: c.posY, w: valueW - 4, h: 14, align: .right)
        c.posY += 18
    }

    private func drawApprovalBlock() {
        c.ensureSpace(60)
        c.posY += 4
        c.put("APPROVAL", font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: 200, h: 12)
        c.posY += 14
        let approver = approvedBy ?? mr.approvedByName
        if !approver.isEmpty {
            c.put("Approved by: \(approver)",
                  font: c.fVal, color: c.clrDark,
                  x: c.margin, y: c.posY, w: c.cW, h: 14)
            c.posY += 14
        }
        if let at = mr.approvedAt {
            c.put("Approved at: \(df.string(from: at))",
                  font: c.fVal, color: c.clrMid,
                  x: c.margin, y: c.posY, w: c.cW, h: 14)
            c.posY += 14
        }
        if !mr.approvalNote.isEmpty {
            let h = c.textH(mr.approvalNote, width: c.cW, font: c.fVal)
            c.putWrap("Note: \(mr.approvalNote)",
                      font: c.fVal, color: c.clrMid,
                      x: c.margin, y: c.posY, w: c.cW, h: h + 4)
            c.posY += h + 6
        }
    }

    private func drawTextSection(_ title: String, text: String) {
        guard !text.isEmpty else { return }
        let h = c.textH(text, width: c.cW, font: c.fVal)
        c.ensureSpace(16 + h + 14)
        c.posY += 6
        c.put(title, font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: c.cW, h: 13)
        c.posY += 16
        c.putWrap(text, font: c.fVal, color: c.clrDark,
                  x: c.margin, y: c.posY, w: c.cW, h: h + 4)
        c.posY += h + 10
    }

    private func drawFooter() {
        let now = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        c.put("Generated: \(now)  ·  Aski IQ  ·  \(mr.requestNumber)",
              font: c.fCap, color: c.clrMid,
              x: c.margin, y: c.posY + 4, w: c.cW, h: 12)
    }

    private func decStr(_ d: Decimal) -> String {
        let n = NSDecimalNumber(decimal: d)
        if d == Decimal(Int(truncating: n)) { return "\(Int(truncating: n))" }
        return n.stringValue
    }

    private func currStr(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency; f.currencyCode = "CAD"
        f.maximumFractionDigits = 2; f.minimumFractionDigits = 2
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "$\(d)"
    }
}

// MARK: - Purchase Order PDF Renderer
// Supplier-facing dispatch document. Generated on demand when the PO is
// sent to the supplier — not stored persistently like the MR approval
// PDF, since the operative copy is the one in the supplier's inbox plus
// whatever ProjectDocument ends up registered against the parent project.

final class PurchaseOrderPDFRenderer {

    private let po:           PurchaseOrder
    private let projectName:  String?
    private let c = PDFCanvas()

    private let df: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    init(po: PurchaseOrder, projectName: String? = nil) {
        self.po          = po
        self.projectName = projectName
    }

    func render() -> Data {
        let bounds = CGRect(x: 0, y: 0, width: c.pageW, height: c.pageH)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            c.ctx = ctx
            ctx.beginPage()
            c.posY = c.margin

            drawHeader()
            c.hr(thick: true, color: c.clrBlue)
            drawSupplierBlock()
            c.hr(thick: false, color: c.clrLight)
            if !po.lineItems.isEmpty {
                drawLineItemsTable()
                c.hr(thick: false, color: c.clrLight)
                drawTotals()
            }
            if !po.terms.isEmpty {
                drawTextSection("TERMS", text: po.terms)
            }
            if !po.notes.isEmpty {
                drawTextSection("NOTES", text: po.notes)
            }
            c.hr(thick: true, color: c.clrBlue)
            drawFooter()
        }
    }

    private func drawHeader() {
        let settings = AppSettings.shared
        let companyName = settings.companyName.isEmpty ? "BLAIR VENTURES" : settings.companyName.uppercased()

        let logoSize: CGFloat = 50
        var nameX = c.margin
        if let logo = UIImage(named: "AskiIQPrimaryLogo") {
            let rect = CGRect(x: c.margin, y: c.posY - 4, width: logoSize, height: logoSize)
            logo.draw(in: rect)
            nameX = c.margin + logoSize + 12
        }

        c.put(companyName, font: c.fCo, color: c.clrBlue,
              x: nameX, y: c.posY, w: c.cW - 130 - (nameX - c.margin), h: 26)
        c.drawBadge("PURCHASE ORDER", color: c.clrBlue,
                    rightX: c.pageW - c.margin, topY: c.posY + 4)
        c.posY += 30
        c.put(po.poNumber, font: c.fMon, color: c.clrDark,
              x: nameX, y: c.posY, w: c.cW - (nameX - c.margin), h: 14)
        c.posY += 16
        var parts: [String] = []
        if !settings.companyAddress.isEmpty { parts.append(settings.companyAddress) }
        if !settings.companyPhone.isEmpty   { parts.append(settings.companyPhone)   }
        if !settings.companyEmail.isEmpty   { parts.append(settings.companyEmail)   }
        if !parts.isEmpty {
            c.put(parts.joined(separator: "  |  "), font: c.fCap, color: c.clrMid,
                  x: nameX, y: c.posY, w: c.cW - (nameX - c.margin), h: 12)
            c.posY += 14
        }
        if c.posY < logoSize + 4 { c.posY = logoSize + 4 }
        c.posY += 4
    }

    private func drawSupplierBlock() {
        let col1W: CGFloat = c.cW * 0.54
        let col2X = c.margin + col1W + 20
        let col2W = c.cW - col1W - 20
        let startY = c.posY

        c.put("SUPPLIER", font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: col1W, h: 13)
        c.posY += 16
        if !po.supplierName.isEmpty {
            c.put(po.supplierName,
                  font: UIFont.systemFont(ofSize: 10.5, weight: .semibold), color: c.clrDark,
                  x: c.margin, y: c.posY, w: col1W, h: 14)
            c.posY += 16
        }
        if !po.deliveryAddress.isEmpty {
            c.put("DELIVER TO", font: c.fLbl, color: c.clrMid,
                  x: c.margin, y: c.posY, w: col1W, h: 12)
            c.posY += 13
            let h = c.textH(po.deliveryAddress, width: col1W, font: c.fVal)
            c.putWrap(po.deliveryAddress, font: c.fVal, color: c.clrDark,
                      x: c.margin, y: c.posY, w: col1W, h: h + 4)
            c.posY += h + 6
        }

        var pairs: [(String, String)] = [
            ("Issue Date", df.string(from: po.issueDate)),
        ]
        if let req = po.requiredDate {
            pairs.append(("Required By", df.string(from: req)))
        }
        if let proj = projectName, !proj.isEmpty {
            pairs.append(("Project", proj))
        }
        pairs.append(("Status", po.status.displayName))

        var rightY = startY
        for (lbl, val) in pairs {
            c.put(lbl + ":", font: c.fLbl, color: c.clrMid,
                  x: col2X, y: rightY, w: 90, h: 14)
            c.put(val, font: c.fVal, color: c.clrDark,
                  x: col2X + 92, y: rightY, w: col2W - 92, h: 14)
            rightY += 16
        }
        c.posY = max(c.posY, rightY) + 8
    }

    private func drawLineItemsTable() {
        c.ensureSpace(50)
        c.put("LINE ITEMS", font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: 200, h: 12)
        c.posY += 14

        let descW: CGFloat = c.cW * 0.50
        let unitW: CGFloat = c.cW * 0.10
        let qtyW:  CGFloat = c.cW * 0.10
        let costW: CGFloat = c.cW * 0.14
        let amtW:  CGFloat = c.cW - descW - unitW - qtyW - costW
        let col2 = c.margin + descW
        let col3 = col2 + unitW
        let col4 = col3 + qtyW
        let col5 = col4 + costW

        UIColor(white: 0.94, alpha: 1).setFill()
        UIBezierPath(rect: CGRect(x: c.margin, y: c.posY, width: c.cW, height: 16)).fill()

        c.put("DESCRIPTION", font: c.fSec, color: c.clrMid,
              x: c.margin + 4, y: c.posY + 2, w: descW - 6, h: 12)
        c.put("UNIT", font: c.fSec, color: c.clrMid,
              x: col2, y: c.posY + 2, w: unitW - 4, h: 12, align: .center)
        c.put("QTY", font: c.fSec, color: c.clrMid,
              x: col3, y: c.posY + 2, w: qtyW - 4, h: 12, align: .right)
        c.put("UNIT COST", font: c.fSec, color: c.clrMid,
              x: col4, y: c.posY + 2, w: costW - 4, h: 12, align: .right)
        c.put("AMOUNT", font: c.fSec, color: c.clrMid,
              x: col5, y: c.posY + 2, w: amtW - 4, h: 12, align: .right)
        c.posY += 18

        for (i, item) in po.lineItems.enumerated() {
            let descText = item.costCode.isEmpty
                ? item.description
                : "[\(item.costCode)]  \(item.description)"
            let descH = max(14, c.textH(descText, width: descW - 8, font: c.fVal))
            let rowH  = descH + 6
            c.ensureSpace(rowH + 4)

            let bg = i % 2 == 0 ? UIColor.white : UIColor(white: 0.97, alpha: 1)
            bg.setFill()
            UIBezierPath(rect: CGRect(x: c.margin, y: c.posY, width: c.cW, height: rowH)).fill()

            c.putWrap(descText, font: c.fVal, color: c.clrDark,
                      x: c.margin + 4, y: c.posY + 2, w: descW - 8, h: descH)
            c.put(item.unit.displayName, font: c.fVal, color: c.clrDark,
                  x: col2, y: c.posY + 2, w: unitW - 4, h: 14, align: .center)
            c.put(decStr(item.quantity), font: c.fVal, color: c.clrDark,
                  x: col3, y: c.posY + 2, w: qtyW - 4, h: 14, align: .right)
            c.put(currStr(item.unitCost), font: c.fVal, color: c.clrDark,
                  x: col4, y: c.posY + 2, w: costW - 4, h: 14, align: .right)
            c.put(currStr(item.totalCost), font: c.fMon, color: c.clrDark,
                  x: col5, y: c.posY + 2, w: amtW - 4, h: 14, align: .right)
            c.posY += rowH
        }
    }

    private func drawTotals() {
        c.ensureSpace(60)
        let labelW: CGFloat = 100
        let valueW: CGFloat = 90
        let rightX  = c.pageW - c.margin - valueW - labelW

        func row(_ label: String, _ value: String, bold: Bool = false) {
            let font  = bold ? c.fHdr : c.fVal
            let clr   = bold ? c.clrDark : c.clrMid
            c.put(label, font: c.fVal, color: c.clrMid,
                  x: rightX, y: c.posY, w: labelW - 4, h: 14, align: .right)
            c.put(value, font: font, color: clr,
                  x: rightX + labelW, y: c.posY, w: valueW - 4, h: 14, align: .right)
            c.posY += 16
        }
        row("Subtotal:", currStr(po.subtotal))
        if po.taxAmount > 0 {
            let pct = NSDecimalNumber(decimal: po.taxRate * 100).intValue
            row("GST (\(pct)%):", currStr(po.taxAmount))
        }
        let divX = rightX + 20
        UIColor(white: 0.80, alpha: 1).setStroke()
        let path = UIBezierPath()
        path.move(to:    CGPoint(x: divX, y: c.posY))
        path.addLine(to: CGPoint(x: c.pageW - c.margin, y: c.posY))
        path.lineWidth = 0.5
        path.stroke()
        c.posY += 4
        row("TOTAL:", currStr(po.total), bold: true)
        c.posY += 4
    }

    private func drawTextSection(_ title: String, text: String) {
        guard !text.isEmpty else { return }
        let h = c.textH(text, width: c.cW, font: c.fVal)
        c.ensureSpace(16 + h + 14)
        c.posY += 6
        c.put(title, font: c.fSec, color: c.clrBlue,
              x: c.margin, y: c.posY, w: c.cW, h: 13)
        c.posY += 16
        c.putWrap(text, font: c.fVal, color: c.clrDark,
                  x: c.margin, y: c.posY, w: c.cW, h: h + 4)
        c.posY += h + 10
    }

    private func drawFooter() {
        let now = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        c.put("Generated: \(now)  ·  Aski IQ  ·  \(po.poNumber)",
              font: c.fCap, color: c.clrMid,
              x: c.margin, y: c.posY + 4, w: c.cW, h: 12)
    }

    private func decStr(_ d: Decimal) -> String {
        let n = NSDecimalNumber(decimal: d)
        if d == Decimal(Int(truncating: n)) { return "\(Int(truncating: n))" }
        return n.stringValue
    }

    private func currStr(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency; f.currencyCode = "CAD"
        f.maximumFractionDigits = 2; f.minimumFractionDigits = 2
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "$\(d)"
    }
}
#endif
