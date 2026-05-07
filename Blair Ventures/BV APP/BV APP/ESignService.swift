// ESignService.swift
// Aski IQ — E-signature integration for contracts (Tier A).
//
// PROVIDER
// Phase 1 ships with Dropbox Sign (formerly HelloSign). The DB
// schema includes a `provider` column (`hellosign | docusign`) so we
// can add DocuSign behind the same UI later — DocuSign needs JWT
// auth + RSA key generation which is materially harder.
//
// FLOW (admin only)
//   1. Admin opens a contract that has a primary PDF attached.
//   2. Taps "Send for E-Signature." Sheet pre-fills counterparty
//      name + email (from the contract record), admin confirms.
//   3. iOS calls `signing-create-request` Edge Function with
//      `{ contract_id, signer_name, signer_email }`.
//   4. Edge Function pulls the PDF from Storage, posts it to Dropbox
//      Sign, persists `e_signature_requests` row, stamps
//      `contracts.signature_status = 'sent'`.
//   5. The signer receives Dropbox Sign's email + signs in the
//      browser (no app required on their end).
//   6. Webhook fires; on `signature_request_all_signed` we download
//      the signed PDF and stamp `contracts.executed_date = now()`.
//
// UI STATE TRANSITIONS
// `contract.signatureStatus` (denormalized column) drives the badge
// next to the Send button:
//   nil              → "Send for E-Signature" (primary action)
//   sent / viewed    → "Awaiting Signature" (secondary, can resend)
//   in_progress      → "Awaiting Signature" + counterparty viewed
//   signed           → "✓ Signed" badge, signed PDF link
//   declined         → red "Declined — resend?" with reason
//   cancelled        → cancelled badge, allow resend

import Foundation
import Combine
import SwiftUI
import Supabase
import Functions

@MainActor
final class ESignService: ObservableObject {

    static let shared = ESignService()
    private init() {}

    // MARK: - Models

    /// Mirrors `e_signature_requests` row shape for client reads.
    struct Request: Identifiable, Decodable, Equatable {
        let id:                  UUID
        let contract_id:         UUID
        let provider:            String
        let external_request_id: String?
        let signer_name:         String
        let signer_email:        String
        let status:              String
        let sent_at:             String?
        let viewed_at:           String?
        let signed_at:           String?
        let declined_at:         String?
        let decline_reason:      String?
        let download_url:        String?

        var statusDisplay: String {
            switch status {
            case "sent":      return "Sent — awaiting signer"
            case "viewed":    return "Viewed by signer"
            case "signed":    return "✓ Signed"
            case "declined":  return "Declined"
            case "cancelled": return "Cancelled"
            default:          return status.capitalized
            }
        }

        var isTerminal: Bool {
            status == "signed" || status == "declined" || status == "cancelled"
        }
    }

    enum ESignError: Error, LocalizedError {
        case notConfigured
        case noDocument
        case adminRequired
        case unauthorized
        case server(String)
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "E-signature isn't activated. Ask your admin to set HELLOSIGN_API_KEY in Supabase secrets."
            case .noDocument:
                return "Upload a contract PDF first — there's nothing to sign."
            case .adminRequired:
                return "Only admins can send signature requests."
            case .unauthorized:
                return "Your session expired. Sign in again."
            case .server(let m): return "E-signature error: \(m)"
            case .transport(let e): return "Network error: \(e.localizedDescription)"
            }
        }
    }

    // MARK: - Send

    struct SendResult: Decodable {
        let request_id:           UUID
        let external_request_id:  String?
        let status:               String
        let test_mode:            Bool?
    }

    /// Sends the contract for signing. Server pulls the PDF, posts to
    /// Dropbox Sign, persists tracking row, stamps the contract.
    func sendForSigning(
        contractID: UUID,
        signerName: String,
        signerEmail: String,
        subject: String? = nil,
        message: String? = nil
    ) async throws -> SendResult {
        struct Params: Encodable {
            let contract_id:  String
            let signer_name:  String
            let signer_email: String
            let subject:      String?
            let message:      String?
        }
        do {
            let body = try JSONEncoder().encode(Params(
                contract_id:  contractID.uuidString,
                signer_name:  signerName,
                signer_email: signerEmail,
                subject:      subject,
                message:      message
            ))
            let resp: SendResult = try await supabase.functions.invoke(
                "signing-create-request",
                options: FunctionInvokeOptions(
                    method: .post,
                    headers: ["Content-Type": "application/json"],
                    body: body
                )
            )
            return resp
        } catch let funcErr as FunctionsError {
            throw map(funcErr)
        } catch {
            throw ESignError.transport(error)
        }
    }

    // MARK: - Read

    /// Fetches all signature requests for a contract, newest first.
    /// RLS scopes to the company so cross-tenant reads return empty.
    func fetchRequests(forContractID contractID: UUID) async throws -> [Request] {
        do {
            let rows: [Request] = try await supabase
                .from("e_signature_requests")
                .select("id, contract_id, provider, external_request_id, signer_name, signer_email, status, sent_at, viewed_at, signed_at, declined_at, decline_reason, download_url")
                .eq("contract_id", value: contractID.uuidString)
                .order("created_at", ascending: false)
                .execute()
                .value
            return rows
        } catch {
            throw ESignError.transport(error)
        }
    }

    // MARK: - Map errors

    private func map(_ err: FunctionsError) -> ESignError {
        switch err {
        case .httpError(let code, let data):
            let env = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let msg = (env?["error"] as? String) ?? "HTTP \(code)"
            switch code {
            case 401: return .unauthorized
            case 403: return msg.lowercased().contains("admin") ? .adminRequired : .server(msg)
            case 412: return .noDocument
            case 503: return .notConfigured
            default:  return .server(msg)
            }
        case .relayError:
            return .server("Edge function relay error.")
        }
    }
}

// MARK: - Send Sheet (presented from ContractDetailView)

struct ContractSendForSigningSheet: View {
    let contract: Contract
    let onSent: (() -> Void)?
    @Environment(\.dismiss) var dismiss

    @State private var signerName: String
    @State private var signerEmail: String
    @State private var subject: String
    @State private var message: String
    @State private var isSending = false
    @State private var error: String?
    @State private var success = false

    init(contract: Contract, onSent: (() -> Void)? = nil) {
        self.contract = contract
        self.onSent = onSent
        _signerName  = State(initialValue: contract.counterpartyName)
        _signerEmail = State(initialValue: contract.counterpartyEmail ?? "")
        _subject     = State(initialValue: "Please sign: \(contract.title)")
        _message     = State(initialValue:
            "Hi \(contract.counterpartyName),\n\n" +
            "Please review and sign the attached contract. " +
            "Reach out with any questions before signing.\n\nThanks!"
        )
    }

    private var canSend: Bool {
        !signerName.trimmingCharacters(in: .whitespaces).isEmpty &&
        signerEmail.contains("@") &&
        !isSending && !success
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Dropbox Sign emails the signer a secure link. They sign in the browser — no app needed on their end. We get notified when it's done and the signed PDF lands back in this contract.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .listRowBackground(Color.clear)
                }

                Section("Signer") {
                    HStack {
                        Text("Name")
                        Spacer()
                        TextField("Full name", text: $signerName)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Email")
                        Spacer()
                        TextField("name@company.com", text: $signerEmail)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("Email") {
                    TextField("Subject", text: $subject)
                    TextEditor(text: $message)
                        .frame(minHeight: 100)
                }

                if let err = error {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }

                if success {
                    Section {
                        Label("Sent! The signer will get an email shortly.",
                              systemImage: "paperplane.fill")
                            .foregroundColor(.green)
                    }
                }

                Section {
                    Button {
                        Task { await send() }
                    } label: {
                        HStack {
                            if isSending {
                                ProgressView().scaleEffect(0.85)
                                Text("Sending…")
                            } else if success {
                                Label("Sent", systemImage: "checkmark.seal.fill")
                            } else {
                                Label("Send for Signature", systemImage: "paperplane.fill")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .foregroundColor(.white)
                    }
                    .listRowBackground(canSend || success ? Color.purple : Color.gray)
                    .disabled(!canSend && !success)
                }
            }
            .navigationTitle("Send for Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(success ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
    }

    private func send() async {
        isSending = true
        error = nil
        defer { isSending = false }
        do {
            _ = try await ESignService.shared.sendForSigning(
                contractID:  contract.id,
                signerName:  signerName,
                signerEmail: signerEmail,
                subject:     subject.isEmpty ? nil : subject,
                message:     message.isEmpty ? nil : message
            )
            success = true
            onSent?()
            // Auto-dismiss after a beat so the success state is visible.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            dismiss()
        } catch let err as ESignService.ESignError {
            error = err.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}
