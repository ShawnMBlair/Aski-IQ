// EmailService.swift
// Aski IQ – Outbound transactional email via the `send-email` Edge Function.
//
// The Edge Function holds the Resend API key in Supabase secrets, so the iOS
// app never sees the upstream credentials. The function also writes an
// audit_snapshots row for every send (or failed send), giving us a per-tenant
// trail of who emailed what.
//
// USAGE
//   let result = await EmailService.shared.sendPDF(
//       to:          ["client@example.com"],
//       subject:     "Quote AKI-2026-0001",
//       bodyText:    "Hi Sarah, please find your quote attached…",
//       pdfData:     pdfBytes,
//       pdfFilename: "Quote_AKI-2026-0001.pdf",
//       entityType:  "quote",
//       entityID:    quote.id
//   )
//   switch result {
//   case .success:                /* show confirmation toast */
//   case .failure(let err):       /* show err.userMessage */
//   }

import Foundation
import Supabase
import Functions

@MainActor
final class EmailService {

    static let shared = EmailService()
    private init() {}

    // MARK: - Errors

    enum EmailError: Error, LocalizedError {
        /// Edge Function returned 503 — RESEND_API_KEY / FROM_EMAIL not configured.
        case notConfigured
        /// Edge Function returned 401 — caller's session is invalid.
        case unauthorized
        /// Edge Function returned 4xx other than the above (validation, missing fields).
        case clientError(String)
        /// Edge Function returned 5xx (other than 503), or upstream Resend rejection.
        case serverError(String)
        /// Local SDK / network failure.
        case transport(Error)

        var errorDescription: String? { userMessage }

        var userMessage: String {
            switch self {
            case .notConfigured:
                return "Email isn't configured yet. An admin needs to set RESEND_API_KEY and PLATFORM_FROM_EMAIL in Supabase Edge Function secrets."
            case .unauthorized:
                return "Your session expired — please sign in again."
            case .clientError(let msg):
                return msg.isEmpty ? "We couldn't send that email. Check the recipient address and try again." : msg
            case .serverError(let msg):
                return msg.isEmpty ? "Email service is temporarily unavailable. Please try again shortly." : msg
            case .transport(let err):
                return "Network error: \(err.localizedDescription)"
            }
        }
    }

    // MARK: - Public API

    /// Send an email with an attached PDF. Returns Result so callers can
    /// surface a success toast vs an error alert without try/catch boilerplate.
    func sendPDF(
        to recipients: [String],
        subject:       String,
        bodyText:      String,
        bodyHTML:      String? = nil,
        replyTo:       String? = nil,
        pdfData:       Data,
        pdfFilename:   String,
        entityType:    String,
        entityID:      UUID
    ) async -> Result<Void, EmailError> {
        // Encode the PDF as base64 — Resend accepts base64 attachments by name.
        let base64 = pdfData.base64EncodedString()
        var attachments: [[String: String]] = [[
            "filename":       pdfFilename,
            "content_base64": base64,
            "content_type":   "application/pdf",
        ]]
        // (placeholder — additional attachments could be added here later)
        _ = attachments

        var payload: [String: Any] = [
            "to":           recipients,
            "subject":      subject,
            "text":         bodyText,
            "attachments":  attachments,
            "entity_type":  entityType,
            "entity_id":    entityID.uuidString,
        ]
        if let bodyHTML { payload["html"] = bodyHTML }
        if let replyTo  { payload["reply_to"] = replyTo }

        return await invokeFunction(name: "send-email", payload: payload)
    }

    /// Send a plain-text email with no attachments. Used by flows that
    /// just need to ship a magic link (lien-waiver bulk requests,
    /// notifications, etc.) without dragging a PDF blob along.
    func sendText(
        to recipients: [String],
        subject:       String,
        bodyText:      String,
        bodyHTML:      String? = nil,
        replyTo:       String? = nil,
        entityType:    String,
        entityID:      UUID
    ) async -> Result<Void, EmailError> {
        var payload: [String: Any] = [
            "to":          recipients,
            "subject":     subject,
            "text":        bodyText,
            "entity_type": entityType,
            "entity_id":   entityID.uuidString,
        ]
        if let bodyHTML { payload["html"]     = bodyHTML }
        if let replyTo  { payload["reply_to"] = replyTo }
        return await invokeFunction(name: "send-email", payload: payload)
    }

    // MARK: - Internal

    /// Calls a Supabase Edge Function via the Supabase SDK. The SDK throws
    /// `FunctionsError.httpError(code:, data:)` on non-2xx, which we catch
    /// and map back to typed errors so the UI can surface a useful message.
    private func invokeFunction(
        name: String,
        payload: [String: Any]
    ) async -> Result<Void, EmailError> {
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            try await supabase.functions.invoke(
                name,
                options: FunctionInvokeOptions(
                    method: .post,
                    headers: ["Content-Type": "application/json"],
                    body: body
                )
            )
            return .success(())
        } catch let funcErr as FunctionsError {
            switch funcErr {
            case .httpError(let code, let data):
                let msg = extractErrorMessage(from: data)
                switch code {
                case 401:        return .failure(.unauthorized)
                case 503:        return .failure(.notConfigured)
                case 400..<500:  return .failure(.clientError(msg))
                default:         return .failure(.serverError(msg))
                }
            case .relayError:
                return .failure(.serverError("Edge Function relay error."))
            }
        } catch {
            return .failure(.transport(error))
        }
    }

    /// Pulls `{ "error": "..." }` from the Edge Function body if present,
    /// otherwise falls back to the raw UTF-8 string.
    private func extractErrorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = json["error"] as? String {
            return msg
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
