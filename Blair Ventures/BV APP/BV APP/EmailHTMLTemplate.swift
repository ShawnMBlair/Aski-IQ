// EmailHTMLTemplate.swift
// Aski IQ — Branded HTML wrapper for outbound transactional emails.
//
// Pre-fix every send went out as plain text — fine for low-stakes
// notifications but unprofessional for client-facing quote PDFs and
// magic-link acceptance emails. EmailService.sendPDF / sendText
// already accept an optional `bodyHTML:` parameter; this helper
// produces the HTML version from the same plain-text body callers
// already build.
//
// DESIGN
//   • One canonical wrapper — every outbound email looks the same.
//   • Inline styles only — many email clients strip <style> blocks.
//   • Mobile-friendly — max-width: 600px, fluid layout.
//   • Light-mode only — dark-mode email rendering is hostile across
//     clients (Gmail's auto-dark inverts brand colors badly).
//   • Plain-text body is preserved verbatim as the fallback inside
//     the HTML <pre>-style block, so newlines and acceptance links
//     paste-test correctly.
//
// HTML EMAIL CAVEATS
// HTML email is famously inconsistent. The wrapper below uses ONLY
// the subset that renders reliably in Outlook/Gmail/Apple Mail/iOS
// Mail: tables for layout, inline styles, no flex/grid, no @media.
// Don't extend this without testing on those four clients first.

import Foundation

enum EmailHTMLTemplate {

    /// Wraps a plain-text body in branded HTML chrome.
    /// Caller passes the same body they'd hand to bodyText; HTML
    /// version preserves newlines and embeds clickable links.
    ///
    /// - Parameters:
    ///   - plainText: the email body the caller already built
    ///   - companyName: shown in the header. Falls back to "Aski IQ"
    ///   - subject: rendered as a sub-header above the body
    ///   - footerNote: optional small print at the bottom
    /// - Returns: a complete HTML document ready to ship as bodyHTML
    static func wrap(
        plainText: String,
        companyName: String? = nil,
        subject: String? = nil,
        footerNote: String? = nil
    ) -> String {
        let brand = (companyName?.trimmingCharacters(in: .whitespaces).isEmpty == false)
            ? companyName!
            : "Aski IQ"
        let bodyHTML = preserveNewlinesAndLinks(plainText)
        let subjectBlock = subject.map { #"<h2 style="margin:0 0 16px;font-size:18px;color:#1d1d1f;font-weight:600;">\#(escapeHTML($0))</h2>"# } ?? ""
        let footer = footerNote ?? "Sent via Aski IQ. Reply to this email to respond directly."

        return #"""
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\#(escapeHTML(subject ?? brand))</title>
        </head>
        <body style="margin:0;padding:0;background:#f5f5f7;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:#1d1d1f;">
          <table role="presentation" cellpadding="0" cellspacing="0" width="100%" style="background:#f5f5f7;padding:24px 12px;">
            <tr>
              <td align="center">
                <table role="presentation" cellpadding="0" cellspacing="0" width="600" style="max-width:600px;background:#ffffff;border-radius:14px;box-shadow:0 1px 3px rgba(0,0,0,.06),0 8px 24px rgba(0,0,0,.04);">
                  <tr>
                    <td style="padding:28px 32px 20px;border-bottom:1px solid #ececef;">
                      <div style="font-size:13px;color:#0070f3;font-weight:600;letter-spacing:.04em;text-transform:uppercase;">\#(escapeHTML(brand))</div>
                    </td>
                  </tr>
                  <tr>
                    <td style="padding:24px 32px 8px;">
                      \#(subjectBlock)
                      <div style="font-size:15px;line-height:1.55;color:#1d1d1f;">
                        \#(bodyHTML)
                      </div>
                    </td>
                  </tr>
                  <tr>
                    <td style="padding:20px 32px 28px;border-top:1px solid #ececef;">
                      <div style="font-size:12px;color:#8e8e93;line-height:1.45;">
                        \#(escapeHTML(footer))
                      </div>
                    </td>
                  </tr>
                </table>
              </td>
            </tr>
          </table>
        </body>
        </html>
        """#
    }

    // MARK: - Internals

    /// Escapes the five HTML metacharacters. Used everywhere a string
    /// gets interpolated into the template.
    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Converts the plain-text body into HTML:
    ///   • Escapes HTML metachars first
    ///   • Linkifies http(s) URLs and mailto-style addresses (so the
    ///     magic-link acceptance URLs become real <a> tags)
    ///   • Replaces newlines with <br> (preserves rep formatting)
    private static func preserveNewlinesAndLinks(_ s: String) -> String {
        let escaped = escapeHTML(s)

        // Linkify URLs. Conservative pattern — no greedy matches, no
        // weird trailing-punctuation issues. Captures http/https/www.
        let urlPattern = #"((?:https?:\/\/|www\.)[^\s<>"]+)"#
        guard let urlRegex = try? NSRegularExpression(pattern: urlPattern, options: [.caseInsensitive]) else {
            return escaped.replacingOccurrences(of: "\n", with: "<br>")
        }
        let nsRange = NSRange(escaped.startIndex..<escaped.endIndex, in: escaped)
        var withLinks = escaped
        let matches = urlRegex.matches(in: escaped, options: [], range: nsRange).reversed()
        for match in matches {
            guard let r = Range(match.range, in: escaped) else { continue }
            let url = String(escaped[r])
            let href = url.hasPrefix("www.") ? "https://" + url : url
            let anchor = #"<a href="\#(href)" style="color:#0070f3;text-decoration:underline;">\#(url)</a>"#
            if let replaceR = withLinks.range(of: url) {
                withLinks.replaceSubrange(replaceR, with: anchor)
            }
        }
        return withLinks.replacingOccurrences(of: "\n", with: "<br>")
    }
}
