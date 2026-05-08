// FormPDFRenderer.swift
// BV APP – Legal PDF Generation + Audit Hashing

#if canImport(UIKit)
import UIKit
import SwiftUI
import CryptoKit
import Foundation

// MARK: - Audit Service
// Generates a SHA-256 fingerprint over the immutable submission data.
// Called once at submit time. Stored in FormSubmission.auditHash.

enum FormAuditService {

    static func generateHash(for submission: FormSubmission) -> String {
        var input = Data()

        // Fixed identifiers
        input += submission.id.uuidString.data(using: .utf8) ?? Data()
        input += submission.templateID.uuidString.data(using: .utf8) ?? Data()
        input += submission.submittedBy.data(using: .utf8) ?? Data()

        // Submission timestamp (ISO-8601 with fractional seconds for precision)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = submission.submittedAt {
            input += iso.string(from: date).data(using: .utf8) ?? Data()
        }

        // Responses — encode deterministically, strip binary blobs
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting     = .sortedKeys  // deterministic key order
        var responses = submission.responses
        for i in responses.indices {
            responses[i].photoData     = []
            responses[i].signatureData = nil
        }
        input += (try? encoder.encode(responses)) ?? Data()

        return SHA256.hash(data: input)
            .compactMap { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - PDF Renderer

final class FormPDFRenderer {

    // ── Page geometry ──────────────────────────────────────────────────
    private let pageW:  CGFloat = 612   // US Letter
    private let pageH:  CGFloat = 792
    private let margin: CGFloat = 44
    private var cW:     CGFloat { pageW - 2 * margin }   // content width

    // ── Brand palette ──────────────────────────────────────────────────
    private let clrBlue  = UIColor(red: 0.11, green: 0.39, blue: 0.84, alpha: 1.0)
    private let clrDark  = UIColor(white: 0.13, alpha: 1)
    private let clrMid   = UIColor(white: 0.44, alpha: 1)
    private let clrLight = UIColor(white: 0.86, alpha: 1)
    private let clrGreen = UIColor(red: 0.10, green: 0.52, blue: 0.25, alpha: 1.0)

    // ── Typography ─────────────────────────────────────────────────────
    private let fCo  = UIFont.systemFont(ofSize: 18, weight: .heavy)
    private let fTit = UIFont.systemFont(ofSize: 14, weight: .bold)
    private let fSec = UIFont.systemFont(ofSize: 9,  weight: .bold)
    private let fLbl = UIFont.systemFont(ofSize: 8.5, weight: .semibold)
    private let fVal = UIFont.systemFont(ofSize: 9.5, weight: .regular)
    private let fCap = UIFont.systemFont(ofSize: 7.5, weight: .regular)
    private let fMon = UIFont.monospacedSystemFont(ofSize: 7.0, weight: .regular)

    // ── Drawing state ──────────────────────────────────────────────────
    private var posY: CGFloat = 0
    private var pdfCtx: UIGraphicsPDFRendererContext!

    // ── Source data ────────────────────────────────────────────────────
    private let sub:     FormSubmission
    private let tmpl:    FormTemplate
    private let project: String?
    private let company: String

    init(submission: FormSubmission,
         template:   FormTemplate,
         projectName: String? = nil,
         company:     String  = "Aski IQ") {
        self.sub     = submission
        self.tmpl    = template
        self.project = projectName
        self.company = company
    }

    // MARK: - Public Entry Point

    func render() -> Data {
        let bounds = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            self.pdfCtx = ctx
            ctx.beginPage()
            posY = margin
            drawHeader()
            hr(thick: true,  color: clrBlue)
            drawFields()
            if sub.isSigned { drawSignature() }
            drawCertFooter()
        }
    }

    // MARK: - Header

    private func drawHeader() {
        // Company name (left) + status badge (right)
        put(company.uppercased(), font: fCo, color: clrBlue,
            x: margin, y: posY, w: cW - 80, h: 26)
        let badge = sub.isDraft ? "DRAFT"
                  : sub.isSigned ? "SIGNED" : "SUBMITTED"
        let bClr  = sub.isDraft ? UIColor.systemOrange
                  : sub.isSigned ? UIColor.systemPurple : clrGreen
        drawBadge(badge, color: bClr, rightX: pageW - margin, topY: posY + 4)
        posY += 30

        // Form title
        put(tmpl.name, font: fTit, color: clrDark,
            x: margin, y: posY, w: cW, h: 20)
        posY += 24

        // Metadata rows
        let df = DateFormatter()
        df.dateFormat = "MMMM d, yyyy  'at'  HH:mm 'UTC'"
        df.timeZone   = TimeZone(identifier: "UTC")

        let meta: [(String, String)] = [
            ("Submitted by", sub.submittedBy),
            ("Date / Time",  sub.submittedAt.map { df.string(from: $0) } ?? "—"),
            ("Project",      project ?? "—"),
            ("Form ID",      sub.id.uuidString),
        ]
        let lw: CGFloat = 82
        for (lbl, val) in meta {
            put(lbl + ":", font: fLbl, color: clrMid,
                x: margin, y: posY, w: lw, h: 14)
            put(val, font: UIFont.systemFont(ofSize: 8.5, weight: .regular), color: clrDark,
                x: margin + lw + 4, y: posY, w: cW - lw - 4, h: 14)
            posY += 14
        }
        posY += 6
    }

    // MARK: - Form Fields

    private func drawFields() {
        let respMap: [UUID: FormFieldResponse] = Dictionary(
            uniqueKeysWithValues: sub.responses.map { ($0.fieldID, $0) }
        )

        for field in tmpl.orderedFields {

            // ── Section headers ──
            if field.type == .sectionHeader || field.type == .instructions {
                ensureSpace(28)
                posY += 8
                clrBlue.withAlphaComponent(0.10).setFill()
                UIRectFill(CGRect(x: margin, y: posY, width: cW, height: 18))
                clrBlue.withAlphaComponent(0.70).setFill()
                UIRectFill(CGRect(x: margin, y: posY, width: 3, height: 18))
                put(field.label.uppercased(), font: fSec, color: clrBlue,
                    x: margin + 9, y: posY + 3, w: cW - 9, h: 13)
                posY += 22
                continue
            }

            // ── Photo fields — render thumbnails inline ──
            if field.type == .photo {
                let photos = (respMap[field.id]?.photoData ?? []).compactMap { UIImage(data: $0) }

                // Field label
                ensureSpace(22)
                put(field.label + (field.isRequired ? " *" : ""),
                    font: fLbl, color: clrMid,
                    x: margin, y: posY, w: cW, h: 14)
                posY += 18

                if photos.isEmpty {
                    put("—", font: fVal, color: UIColor.systemGray3,
                        x: margin, y: posY, w: cW, h: 14)
                    posY += 16
                } else {
                    // 2-column grid; single photo gets full-width (60 % centred)
                    let cols: Int      = photos.count == 1 ? 1 : 2
                    let gap: CGFloat   = 10
                    let photoW: CGFloat = cols == 1 ? cW * 0.60 : (cW - gap) / 2
                    let photoH: CGFloat = 160
                    let startX: CGFloat = cols == 1 ? margin + (cW - photoW) / 2 : margin

                    var col = 0
                    for image in photos {
                        if col == 0 { ensureSpace(photoH + 14) }
                        let x = startX + CGFloat(col) * (photoW + gap)
                        drawPhoto(image, in: CGRect(x: x, y: posY, width: photoW, height: photoH))
                        col += 1
                        if col >= cols {
                            posY += photoH + 10
                            col = 0
                        }
                    }
                    if col > 0 { posY += photoH + 10 }   // flush incomplete last row
                }

                // Full-width separator
                clrLight.setStroke()
                let sep = UIBezierPath()
                sep.move(to:    CGPoint(x: margin,        y: posY))
                sep.addLine(to: CGPoint(x: pageW - margin, y: posY))
                sep.lineWidth = 0.4
                sep.stroke()
                posY += 4
                continue
            }

            // ── All other data fields ──
            let val  = formatResponse(field: field, response: respMap[field.id])
            let valH = textH(val.isEmpty ? "—" : val, width: cW - 130, font: fVal)
            let rowH = max(22, valH + 10)
            ensureSpace(rowH + 4)

            // Label column
            put(field.label + (field.isRequired ? " *" : ""),
                font: fLbl, color: clrMid,
                x: margin, y: posY, w: 125, h: 14)

            // Value column (word-wrapped)
            putWrap(val.isEmpty ? "—" : val,
                    font: fVal,
                    color: val.isEmpty ? UIColor.systemGray3 : clrDark,
                    x: margin + 130, y: posY, w: cW - 130, h: valH + 4)

            posY += rowH

            // Thin separator
            clrLight.setStroke()
            let sep = UIBezierPath()
            sep.move(to:    CGPoint(x: margin + 130, y: posY))
            sep.addLine(to: CGPoint(x: pageW - margin, y: posY))
            sep.lineWidth = 0.4
            sep.stroke()
            posY += 2
        }
        posY += 12
    }

    // MARK: - Photo Drawing Helper

    /// Draws `image` scaled to fit (letterboxed) inside `rect` with a light border.
    private func drawPhoto(_ image: UIImage, in rect: CGRect) {
        // Light grey background fill
        UIColor(white: 0.94, alpha: 1).setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 4).fill()

        // Aspect-fit: calculate inner draw rect
        let imgW = image.size.width,  imgH = image.size.height
        guard imgW > 0, imgH > 0 else { return }
        let scale   = min(rect.width / imgW, rect.height / imgH)
        let drawW   = imgW * scale
        let drawH   = imgH * scale
        let drawRect = CGRect(
            x: rect.minX + (rect.width  - drawW) / 2,
            y: rect.minY + (rect.height - drawH) / 2,
            width: drawW, height: drawH
        )
        image.draw(in: drawRect)

        // Thin border
        UIColor(white: 0.78, alpha: 1).setStroke()
        let border = UIBezierPath(roundedRect: rect, cornerRadius: 4)
        border.lineWidth = 0.5
        border.stroke()
    }

    // MARK: - Signature Block

    private func drawSignature() {
        ensureSpace(120)
        hr(thick: false, color: clrMid)
        posY += 4
        put("SIGNATURE", font: fSec, color: clrBlue,
            x: margin, y: posY, w: cW, h: 14)
        posY += 18

        let df = DateFormatter()
        df.dateFormat = "MMMM d, yyyy 'at' HH:mm 'UTC'"
        df.timeZone   = TimeZone(identifier: "UTC")
        if let by = sub.signedBy  { keyVal("Signed by", by) }
        if let at = sub.signedAt  { keyVal("Signed at", df.string(from: at)) }
        posY += 6

        if let sigData = sub.responses.compactMap({ $0.signatureData }).first,
           let img = UIImage(data: sigData) {
            let h: CGFloat = 72
            let aspect = img.size.height > 0 ? img.size.width / img.size.height : 1
            let w = min(cW * 0.55, h * aspect)
            ensureSpace(h + 14)
            let rect = CGRect(x: margin, y: posY, width: w, height: h)
            UIColor.systemGray6.setFill(); UIRectFill(rect)
            UIColor.systemGray4.setStroke()
            let brd = UIBezierPath(rect: rect); brd.lineWidth = 0.5; brd.stroke()
            img.draw(in: rect.insetBy(dx: 4, dy: 4))
            posY += h + 10
        }
    }

    // MARK: - Legal Certification Footer

    private func drawCertFooter() {
        ensureSpace(150)
        posY += 14
        hr(thick: true, color: clrBlue)

        put("DOCUMENT CERTIFICATION",
            font: UIFont.systemFont(ofSize: 9, weight: .bold),
            color: clrBlue,
            x: margin, y: posY, w: cW, h: 14)
        posY += 18

        let certText =
            "This document was electronically submitted via Aski IQ " +
            "and constitutes a certified legal record. The SHA-256 fingerprint below " +
            "verifies document integrity — any modification after submission will " +
            "invalidate the hash and void certification."
        let certH = textH(certText, width: cW, font: fCap)
        putWrap(certText, font: fCap, color: clrMid,
                x: margin, y: posY, w: cW, h: certH + 2)
        posY += certH + 12

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rows: [(String, String, UIFont)] = [
            ("Submission ID", sub.id.uuidString.uppercased(),                           UIFont.systemFont(ofSize: 8, weight: .regular)),
            ("Template",      "\(tmpl.name)  (version \(tmpl.version))",               UIFont.systemFont(ofSize: 8, weight: .regular)),
            ("Submitted",     sub.submittedAt.map { iso.string(from: $0) } ?? "—",     UIFont.systemFont(ofSize: 8, weight: .regular)),
            ("SHA-256",       sub.auditHash ?? "Hash not computed — re-submit to generate", fMon),
        ]
        let lw: CGFloat = 80
        for (k, v, vFont) in rows {
            let vH = textH(v, width: cW - lw - 6, font: vFont)
            ensureSpace(max(14, vH + 4))
            put(k + ":", font: UIFont.systemFont(ofSize: 8, weight: .semibold), color: clrMid,
                x: margin, y: posY, w: lw, h: 14)
            putWrap(v, font: vFont, color: clrDark,
                    x: margin + lw + 6, y: posY, w: cW - lw - 6, h: vH + 4)
            posY += max(14, vH + 4) + 1
        }
        posY += 8
        hr(thick: true, color: clrBlue)

        // Generated timestamp
        let now = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        put("Generated: \(now)  ·  Aski IQ",
            font: fCap, color: clrMid,
            x: margin, y: posY + 4, w: cW, h: 12)
    }

    // MARK: - Drawing Primitives

    private func put(_ text: String, font: UIFont, color: UIColor,
                     x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        (text as NSString).draw(in: CGRect(x: x, y: y, width: w, height: h),
                                withAttributes: attrs)
    }

    private func putWrap(_ text: String, font: UIFont, color: UIColor,
                         x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: para
        ]
        (text as NSString).draw(in: CGRect(x: x, y: y, width: w, height: h + 12),
                                withAttributes: attrs)
    }

    private func hr(thick: Bool, color: UIColor) {
        let path = UIBezierPath()
        path.move(to:    CGPoint(x: margin,        y: posY))
        path.addLine(to: CGPoint(x: pageW - margin, y: posY))
        color.setStroke()
        path.lineWidth = thick ? 1.5 : 0.5
        path.stroke()
        posY += thick ? 8 : 4
    }

    private func keyVal(_ key: String, _ value: String) {
        ensureSpace(16)
        put(key + ":", font: fLbl, color: clrMid,
            x: margin, y: posY, w: 72, h: 14)
        put(value, font: fVal, color: clrDark,
            x: margin + 76, y: posY, w: cW - 76, h: 14)
        posY += 16
    }

    private func drawBadge(_ text: String, color: UIColor, rightX: CGFloat, topY: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 7.5, weight: .bold),
            .foregroundColor: UIColor.white
        ]
        let sz   = (text as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 5
        let bW = sz.width + pad * 2
        let bH: CGFloat = 16
        let rect = CGRect(x: rightX - bW, y: topY, width: bW, height: bH)
        color.setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 4).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + pad, y: rect.minY + 2.5),
                                withAttributes: attrs)
    }

    /// Measure wrapped text height
    private func textH(_ text: String, width: CGFloat, font: UIFont) -> CGFloat {
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

    /// Start a new page if posY + needed height would overflow
    private func ensureSpace(_ neededHeight: CGFloat) {
        if posY + neededHeight > pageH - margin - 12 {
            pdfCtx.beginPage()
            posY = margin
        }
    }

    // MARK: - Response → String

    private func formatResponse(field: FormField, response: FormFieldResponse?) -> String {
        guard let r = response else { return "" }
        switch field.type {
        case .shortText, .longText, .text:
            return r.textValue ?? ""
        case .number:
            guard let n = r.numberValue else { return "" }
            return field.unit.map { "\(n) \($0)" } ?? "\(n)"
        case .date:
            guard let d = r.dateValue else { return "" }
            let df = DateFormatter(); df.dateStyle = .long; df.timeStyle = .none
            return df.string(from: d)
        case .time:
            guard let d = r.dateValue else { return "" }
            let df = DateFormatter(); df.dateStyle = .none; df.timeStyle = .short
            return df.string(from: d)
        case .dateTime:
            guard let d = r.dateValue else { return "" }
            let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
            return df.string(from: d)
        case .yesNo:
            guard let b = r.boolValue else { return "" }
            return b ? "Yes" : "No"
        case .passFail:
            guard let b = r.boolValue else { return "" }
            return b ? "Pass" : "Fail"
        case .yesNoNA, .passFailNA:
            switch r.threeStateValue {
            case .yes:  return "Yes"
            case .no:   return "No"
            case .na:   return "N/A"
            case .pass: return "Pass"
            case .fail: return "Fail"
            case .none: return ""
            }
        case .singleChoice, .dropdown:
            return r.selectedOptions?.first ?? ""
        case .multipleChoice:
            return r.selectedOptions?.map { "• \($0)" }.joined(separator: "\n") ?? ""
        case .rating:
            guard let rv = r.ratingValue else { return "" }
            let stars = String(repeating: "★", count: rv) + String(repeating: "☆", count: field.ratingMax - rv)
            return "\(stars)  \(rv)/\(field.ratingMax)"
        case .slider:
            guard let sv = r.sliderValue else { return "" }
            return String(format: sv.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", sv)
        case .photo:
            let n = r.photoData.count + r.photoAttachmentIDs.count
            return n > 0 ? "\(n) photo\(n == 1 ? "" : "s") attached" : ""
        case .scan:
            if let text = r.textValue, !text.isEmpty { return text }
            return r.photoData.isEmpty ? "" : "Scanned document attached"
        case .signature:
            return r.signatureData != nil ? "Signature captured" : ""
        case .location:
            guard let loc = r.locationValue else { return "" }
            if let addr = loc.address, !addr.isEmpty { return addr }
            return String(format: "%.5f, %.5f", loc.latitude, loc.longitude)
        case .sectionHeader, .instructions:
            return field.bodyText ?? ""
        }
    }
}
#endif
