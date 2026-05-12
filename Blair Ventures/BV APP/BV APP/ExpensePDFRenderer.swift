// ExpensePDFRenderer.swift
// Phase 9 / Expenses v1.1 — PDF report (locked spec, 2026-05-11):
//
// Audience defaults: employee + accountant (Helen) + approver — same
// template, different distribution channels (ShareLink / EmailService).
// Trigger:   on-demand from the queue + batched per employee per pay
//            period.
// Layout:    audit-binder style — clean charge table up front,
//            receipt images appended as separate pages at the back.
//
// Receipt handling: JPG/PNG/HEIC drawn directly via UIImage. Native
// PDF receipts are stitched in via CGPDFDocument page-by-page so they
// render at full fidelity instead of getting re-rasterized. Files with
// unknown types render a placeholder page noting the filename.

#if canImport(UIKit)
import UIKit
import PDFKit

enum ExpensePDFRenderer {

    // MARK: - Public API

    /// Render a packet for the given expenses, with embedded receipts.
    /// Caller decides scope (single expense / per-employee batch /
    /// custom selection) by populating the `expenses` parameter.
    static func render(
        expenses: [Expense],
        attachmentsByID: [UUID: [ExpenseAttachment]],
        companyName: String,
        title: String,
        subtitle: String
    ) -> Data {

        // US Letter portrait, 0.5" margin (36pt).
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 36
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)

        let fH1   = UIFont.systemFont(ofSize: 22, weight: .heavy)
        let fH2   = UIFont.systemFont(ofSize: 13, weight: .bold)
        let fHdr  = UIFont.systemFont(ofSize: 9.5, weight: .bold)
        let fRow  = UIFont.systemFont(ofSize: 9, weight: .regular)
        let fMono = UIFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        let fCap  = UIFont.systemFont(ofSize: 7.5, weight: .regular)

        let clrDark  = UIColor(white: 0.13, alpha: 1)
        let clrMid   = UIColor(white: 0.42, alpha: 1)
        let clrAcc   = UIColor(red: 0.11, green: 0.39, blue: 0.84, alpha: 1.0)
        let clrAlt   = UIColor(white: 0.96, alpha: 1)

        // Column layout — proportional to printable width.
        let printableW = bounds.width - margin * 2
        struct Col { let title: String; let weight: CGFloat; let align: NSTextAlignment }
        let cols: [Col] = [
            .init(title: "Date",       weight: 0.10, align: .left),
            .init(title: "Vendor",     weight: 0.22, align: .left),
            .init(title: "Category",   weight: 0.14, align: .left),
            .init(title: "Destination",weight: 0.20, align: .left),
            .init(title: "Paid By",    weight: 0.12, align: .left),
            .init(title: "Status",     weight: 0.10, align: .left),
            .init(title: "Amount",     weight: 0.12, align: .right)
        ]
        let widths = cols.map { $0.weight * printableW }

        return renderer.pdfData { gctx in
            var posY: CGFloat = 0

            // ── Page break helper ────────────────────────────────────
            func newPage() {
                gctx.beginPage()
                posY = margin
            }

            // ── Text helper ──────────────────────────────────────────
            func draw(_ s: String, font: UIFont, color: UIColor,
                      rect: CGRect, align: NSTextAlignment = .left) {
                let para = NSMutableParagraphStyle()
                para.alignment = align
                para.lineBreakMode = .byTruncatingTail
                (s as NSString).draw(in: rect, withAttributes: [
                    .font: font, .foregroundColor: color, .paragraphStyle: para
                ])
            }

            // ── Page 1: Cover ───────────────────────────────────────
            newPage()
            draw(companyName.uppercased(), font: UIFont.systemFont(ofSize: 9, weight: .bold),
                 color: clrMid, rect: CGRect(x: margin, y: posY, width: printableW, height: 12))
            posY += 14
            draw(title, font: fH1, color: clrDark,
                 rect: CGRect(x: margin, y: posY, width: printableW, height: 32))
            posY += 32
            draw(subtitle, font: fH2, color: clrMid,
                 rect: CGRect(x: margin, y: posY, width: printableW, height: 18))
            posY += 26

            // Summary stats
            let total = expenses.reduce(Decimal(0)) { $0 + $1.amount }
            let reimbursable = expenses
                .filter { $0.isReimbursable }
                .reduce(Decimal(0)) { $0 + $1.amount }
            let attachmentCount = expenses.reduce(0) {
                $0 + (attachmentsByID[$1.id]?.count ?? 0)
            }
            let summary = "\(expenses.count) expense\(expenses.count == 1 ? "" : "s") · \(total.currencyString) total · \(reimbursable.currencyString) reimbursable · \(attachmentCount) receipt\(attachmentCount == 1 ? "" : "s")"
            draw(summary, font: fRow, color: clrDark,
                 rect: CGRect(x: margin, y: posY, width: printableW, height: 14))
            posY += 22

            // ── Charge table header ─────────────────────────────────
            let headerH: CGFloat = 22
            clrAcc.setFill()
            UIBezierPath(rect: CGRect(x: margin, y: posY, width: printableW, height: headerH)).fill()
            var x = margin
            for (i, c) in cols.enumerated() {
                draw(c.title, font: fHdr, color: .white,
                     rect: CGRect(x: x + 6, y: posY + 5, width: widths[i] - 12, height: headerH - 8),
                     align: c.align)
                x += widths[i]
            }
            posY += headerH

            // ── Rows ───────────────────────────────────────────────
            let rowH: CGFloat = 22
            let bottomLimit = bounds.height - margin - 30

            // Re-draw the table header when a row spills onto a new page.
            func drawTableHeader() {
                clrAcc.setFill()
                UIBezierPath(rect: CGRect(x: margin, y: posY, width: printableW, height: headerH)).fill()
                var hx = margin
                for (i, c) in cols.enumerated() {
                    draw(c.title, font: fHdr, color: .white,
                         rect: CGRect(x: hx + 6, y: posY + 5, width: widths[i] - 12, height: headerH - 8),
                         align: c.align)
                    hx += widths[i]
                }
                posY += headerH
            }

            for (idx, e) in expenses.enumerated() {
                if posY + rowH > bottomLimit {
                    newPage()
                    drawTableHeader()
                }
                if idx % 2 == 1 {
                    clrAlt.setFill()
                    UIBezierPath(rect: CGRect(x: margin, y: posY, width: printableW, height: rowH)).fill()
                }

                let destination: String = {
                    switch e.destination {
                    case .company:         return e.companyDestinationLabel.isEmpty ? "Company" : "Company · \(e.companyDestinationLabel)"
                    case .project:         return "Project"
                    case .materialRequest: return "MR"
                    }
                }()

                let values: [(String, NSTextAlignment, UIFont)] = [
                    (e.expenseDate.shortDate,       .left,  fRow),
                    (e.vendor.isEmpty ? "—" : e.vendor, .left, fRow),
                    (e.category.displayName,        .left,  fRow),
                    (destination,                   .left,  fRow),
                    (e.paymentMethod.displayName,   .left,  fRow),
                    (e.approvalState.displayName,   .left,  fRow),
                    (e.amount.currencyString,       .right, fMono)
                ]
                var rx = margin
                for (i, v) in values.enumerated() {
                    draw(v.0, font: v.2, color: clrDark,
                         rect: CGRect(x: rx + 6, y: posY + 5, width: widths[i] - 12, height: rowH - 8),
                         align: v.1)
                    rx += widths[i]
                }
                posY += rowH
            }

            // ── Totals row ────────────────────────────────────────
            if posY + rowH > bottomLimit { newPage() }
            clrDark.setFill()
            UIBezierPath(rect: CGRect(x: margin, y: posY, width: printableW, height: rowH)).fill()
            draw("TOTAL", font: fHdr, color: .white,
                 rect: CGRect(x: margin + 6, y: posY + 5, width: printableW - 12 - widths[6], height: rowH - 8))
            draw(total.currencyString, font: fMono, color: .white,
                 rect: CGRect(x: margin + printableW - widths[6] + 6, y: posY + 5, width: widths[6] - 12, height: rowH - 8),
                 align: .right)
            posY += rowH + 8

            // Footer note
            draw("Generated by Aski IQ · \(Date().longDate)",
                 font: fCap, color: clrMid,
                 rect: CGRect(x: margin, y: bounds.height - margin - 12, width: printableW, height: 12),
                 align: .right)

            // ── Receipt appendix ──────────────────────────────────
            // Each receipt gets its own page so it's readable. Order
            // matches the table order; multiple receipts per expense
            // each render as their own page with a small caption.
            for e in expenses {
                let receipts = attachmentsByID[e.id]?
                    .filter { !$0.isDeleted }
                    .sorted { $0.isPrimaryReceipt && !$1.isPrimaryReceipt } ?? []
                for att in receipts {
                    drawReceiptPage(
                        gctx:   gctx,
                        att:    att,
                        expense: e,
                        bounds: bounds,
                        margin: margin,
                        fH2:    fH2,
                        fCap:   fCap,
                        clrDark: clrDark,
                        clrMid: clrMid
                    )
                }
            }
        }
    }

    // MARK: - Receipt page

    private static func drawReceiptPage(
        gctx: UIGraphicsPDFRendererContext,
        att: ExpenseAttachment,
        expense: Expense,
        bounds: CGRect,
        margin: CGFloat,
        fH2: UIFont,
        fCap: UIFont,
        clrDark: UIColor,
        clrMid: UIColor
    ) {
        let printableW = bounds.width  - margin * 2
        let printableH = bounds.height - margin * 2

        // Native PDF receipts: stitch in each source page so they
        // render at full fidelity.
        if att.fileType == .pdf, let data = att.fileData,
           let doc = PDFDocument(data: data) {
            for i in 0..<doc.pageCount {
                gctx.beginPage()
                let title = "Receipt · \(expense.vendor.isEmpty ? "(no vendor)" : expense.vendor) · \(expense.expenseDate.shortDate)"
                (title as NSString).draw(at: CGPoint(x: margin, y: margin), withAttributes: [
                    .font: fH2, .foregroundColor: clrDark
                ])
                let caption = "\(att.fileName) — page \(i + 1) of \(doc.pageCount) · \(att.displaySize)"
                (caption as NSString).draw(at: CGPoint(x: margin, y: margin + 18), withAttributes: [
                    .font: fCap, .foregroundColor: clrMid
                ])
                if let page = doc.page(at: i) {
                    let imageRect = CGRect(
                        x: margin,
                        y: margin + 40,
                        width: printableW,
                        height: printableH - 40
                    )
                    let pageBounds = page.bounds(for: .mediaBox)
                    let scale = min(
                        imageRect.width / pageBounds.width,
                        imageRect.height / pageBounds.height
                    )
                    let drawW = pageBounds.width * scale
                    let drawH = pageBounds.height * scale
                    let drawRect = CGRect(
                        x: imageRect.midX - drawW / 2,
                        y: imageRect.midY - drawH / 2,
                        width: drawW,
                        height: drawH
                    )
                    gctx.cgContext.saveGState()
                    gctx.cgContext.translateBy(x: drawRect.minX, y: drawRect.maxY)
                    gctx.cgContext.scaleBy(x: scale, y: -scale)
                    page.draw(with: .mediaBox, to: gctx.cgContext)
                    gctx.cgContext.restoreGState()
                }
            }
            return
        }

        // Image receipt — single page.
        gctx.beginPage()
        let title = "Receipt · \(expense.vendor.isEmpty ? "(no vendor)" : expense.vendor) · \(expense.expenseDate.shortDate)"
        (title as NSString).draw(at: CGPoint(x: margin, y: margin), withAttributes: [
            .font: fH2, .foregroundColor: clrDark
        ])
        let caption = "\(att.fileName) · \(att.displaySize)"
        (caption as NSString).draw(at: CGPoint(x: margin, y: margin + 18), withAttributes: [
            .font: fCap, .foregroundColor: clrMid
        ])
        let imageRect = CGRect(
            x: margin,
            y: margin + 40,
            width: printableW,
            height: printableH - 40
        )

        if let data = att.fileData, let img = UIImage(data: data) {
            let scale = min(
                imageRect.width / img.size.width,
                imageRect.height / img.size.height
            )
            let drawW = img.size.width * scale
            let drawH = img.size.height * scale
            let drawRect = CGRect(
                x: imageRect.midX - drawW / 2,
                y: imageRect.midY - drawH / 2,
                width: drawW,
                height: drawH
            )
            img.draw(in: drawRect)
        } else {
            // Placeholder when we can't render the binary
            let placeholder = "(Receipt data unavailable — original file: \(att.fileName))"
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            (placeholder as NSString).draw(in: imageRect, withAttributes: [
                .font: fCap, .foregroundColor: clrMid, .paragraphStyle: para
            ])
        }
    }
}

// MARK: - Date helpers

private extension Date {
    var longDate: String {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f.string(from: self)
    }
}

#endif
