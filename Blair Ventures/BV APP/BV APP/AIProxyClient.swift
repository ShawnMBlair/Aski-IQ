// AIProxyClient.swift
// Aski IQ — Single entry point for every Anthropic API call in the app.
//
// WHY THIS EXISTS
// Before this client, three different services (`AIChatService`,
// `AIDocumentService`, `CRMAIService`) each carried their own URLRequest
// boilerplate calling `https://api.anthropic.com/v1/messages` directly with
// the user's personal Anthropic key from `AppSettings`. That had four
// problems:
//
//   1. The API key shipped on every device. Lost / stolen phone = leaked key.
//   2. Every employee had to provision their own Anthropic key — a huge
//      adoption friction for a 50-person trades company.
//   3. No usage cap, no audit trail, no per-user / per-company attribution.
//   4. The key lived in UserDefaults plaintext, not the Keychain.
//
// SOLUTION
// The `ai-proxy` Edge Function (deployed, version 1, ACTIVE) holds
// `ANTHROPIC_API_KEY` server-side as a Supabase secret, verifies the
// caller's JWT, looks up their `company_id`, forwards the request to
// Anthropic with the server-side key, and writes an `audit_snapshots` row
// for every call. The upstream Anthropic JSON response is returned
// verbatim, so existing response-parsing code on the iOS side doesn't
// change at all — only the URL and auth header change.
//
// USAGE
//   let result = await AIProxyClient.shared.send(payload: [
//       "model":      "claude-haiku-4-5-20251001",
//       "max_tokens": 512,
//       "messages":   [["role": "user", "content": "Hello"]]
//   ])
//   switch result {
//   case .success(let data):
//       // Same JSON shape as `https://api.anthropic.com/v1/messages` — parse as before.
//   case .failure(let err):
//       // err.userMessage gives a human-readable string for the UI.
//   }

import Foundation
import Supabase
import Functions

@MainActor
final class AIProxyClient {

    static let shared = AIProxyClient()
    private init() {}

    enum AIProxyError: Error, LocalizedError {
        /// HTTP 503 — the server-side ANTHROPIC_API_KEY secret isn't set yet.
        /// User-facing message routes them to ask their company admin.
        case notConfigured
        /// HTTP 401 — the user's Supabase JWT is invalid / expired.
        case unauthorized
        /// HTTP 4xx other than 401 — usually a malformed request body.
        case clientError(String)
        /// HTTP 5xx other than 503 — Anthropic upstream blip or our function bug.
        case serverError(String)
        /// URLSession / Functions transport failure.
        case transport(Error)
        /// Couldn't construct the JSON body locally.
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "AI features aren't activated for your company yet. Contact your admin."
            case .unauthorized:
                return "Your session expired. Sign in again."
            case .clientError(let m):
                return "AI request rejected: \(m)"
            case .serverError(let m):
                return "AI service error: \(m)"
            case .transport(let e):
                return "Network error: \(e.localizedDescription)"
            case .encodingFailed:
                return "Couldn't build the request."
            }
        }

        /// Convenience for view code that just wants a string.
        var userMessage: String {
            errorDescription ?? "AI request failed."
        }
    }

    /// Sends a payload to the `ai-proxy` Edge Function. Payload must match
    /// the Anthropic Messages API shape (`model`, `messages`, `max_tokens`,
    /// optional `system`). Returns the upstream response body verbatim.
    func send(payload: [String: Any]) async -> Result<Data, AIProxyError> {
        // Body
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            return .failure(.encodingFailed)
        }

        // Invoke the Edge Function. The Supabase SDK auto-attaches the
        // current user's JWT as `Authorization: Bearer ...` — that's what
        // the function uses to identify the caller and look up company_id.
        // The closure-based `invoke` lets us pull raw Data out (the SDK
        // also offers a `Decodable` variant, but we want to keep the same
        // permissive parsing the existing services rely on).
        do {
            let data: Data = try await supabase.functions.invoke(
                "ai-proxy",
                options: FunctionInvokeOptions(
                    method: .post,
                    headers: ["Content-Type": "application/json"],
                    body: body
                )
            ) { data, _ in data }
            return .success(data)
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

    /// Convenience: send a payload and pull `content[0].text` out of the
    /// Anthropic response. Returns either the assistant text or a typed
    /// error. Three out of three of our existing AI services parse exactly
    /// this shape, so funneling it through one helper kills duplication.
    func sendText(payload: [String: Any]) async -> Result<String, AIProxyError> {
        switch await send(payload: payload) {
        case .failure(let err):
            return .failure(err)
        case .success(let data):
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let content = json["content"] as? [[String: Any]],
               let first = content.first,
               let text = first["text"] as? String {
                return .success(text)
            }
            // Anthropic returned an error envelope — surface its message.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errObj = json["error"] as? [String: Any],
               let msg = errObj["message"] as? String {
                return .failure(.serverError(msg))
            }
            return .failure(.serverError("Unexpected response shape from AI service."))
        }
    }

    // MARK: - Streaming
    //
    // Pairs with `ai-proxy` v5+. When the payload includes
    // `stream: true`, the function pipes back Anthropic's SSE response
    // and we surface tokens to the caller via an `AsyncThrowingStream`.
    //
    // We bypass the Supabase SDK's `functions.invoke` for streaming
    // because the SDK buffers the whole response into a single Data
    // chunk, defeating the point of streaming. Instead we hit the
    // Functions URL directly with URLSession's bytes API and build the
    // Authorization + apikey headers ourselves. Auth pulls the current
    // JWT via `AuthService.currentAccessToken()` (same token the SDK
    // would have attached on our behalf).

    /// Yields successive text deltas from a streaming AI call. Each
    /// element is a chunk of text that should be appended to the
    /// running assistant response — this is NOT the cumulative
    /// response, just the new piece.
    ///
    /// The stream finishes successfully when the upstream SSE emits
    /// `message_stop`. Any HTTP error or upstream `error` SSE event
    /// rethrows as an `AIProxyError`.
    func streamText(payload: [String: Any]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    // Force stream:true on the payload — the function
                    // dispatches based on this flag, and a caller who
                    // forgot to set it would otherwise get a non-stream
                    // JSON body that this method can't parse.
                    var streamed = payload
                    streamed["stream"] = true

                    let body = try JSONSerialization.data(withJSONObject: streamed)

                    // Build the request manually so we can use
                    // URLSession's `bytes(for:)` API for true streaming.
                    let url = supabaseFunctionsBaseURL.appendingPathComponent("ai-proxy")
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.setValue(supabasePublicAnonKey, forHTTPHeaderField: "apikey")

                    let token = try await AuthService.currentAccessToken()
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    req.httpBody = body

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)

                    // Inspect status before consuming body. SSE replies
                    // come back 200; anything else is JSON-shaped and
                    // we should drain + decode it as an error envelope.
                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: AIProxyError.serverError("No HTTP response"))
                        return
                    }
                    if http.statusCode != 200 {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        let msg = self.extractErrorMessage(from: data)
                        switch http.statusCode {
                        case 401: continuation.finish(throwing: AIProxyError.unauthorized)
                        case 503: continuation.finish(throwing: AIProxyError.notConfigured)
                        case 400..<500: continuation.finish(throwing: AIProxyError.clientError(msg))
                        default: continuation.finish(throwing: AIProxyError.serverError(msg))
                        }
                        return
                    }

                    // SSE parser. Anthropic events are line-based:
                    //   event: <name>
                    //   data: <json>
                    //   <blank line>
                    //
                    // We only need `data:` lines and only care about
                    // a few event types — the rest we skip.
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payloadStr = line
                            .dropFirst(5)
                            .trimmingCharacters(in: .whitespaces)
                        if payloadStr.isEmpty || payloadStr == "[DONE]" { continue }
                        guard let data = payloadStr.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }
                        let type = (json["type"] as? String) ?? ""
                        switch type {
                        case "content_block_delta":
                            // {"type":"content_block_delta","delta":{"type":"text_delta","text":"..."}}
                            if let delta = json["delta"] as? [String: Any],
                               let text = delta["text"] as? String,
                               !text.isEmpty {
                                continuation.yield(text)
                            }
                        case "message_stop":
                            // Normal end-of-stream. The bytes loop will
                            // end on its own; we just bail early.
                            break
                        case "error":
                            // {"type":"error","error":{"message":"..."}}
                            let errObj = json["error"] as? [String: Any]
                            let msg = (errObj?["message"] as? String) ?? "AI streaming error"
                            continuation.finish(throwing: AIProxyError.serverError(msg))
                            return
                        default:
                            // message_start / content_block_start / content_block_stop / message_delta /
                            // ping — none carry user-visible deltas, ignore.
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AIProxyError.transport(error))
                }
            }

            // Cancel the URLSession task if the consumer terminates the stream.
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Helpers

    private func extractErrorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = json["error"] as? String {
            return msg
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }
}
