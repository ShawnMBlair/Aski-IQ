// QBOService.swift
// Aski IQ — QuickBooks Online integration (Tier A).
//
// THREE EDGE FUNCTIONS, ONE SERVICE
//   * qbo-connect         → mints OAuth state, returns the Intuit
//                           consent URL for SFSafariViewController.
//   * qbo-oauth-callback  → Intuit redirects here. Verifies state,
//                           exchanges code, persists tokens.
//   * qbo-push-invoice    → pushes (creates / updates) one invoice
//                           into QBO. Resolves the customer first,
//                           then creates the QBO invoice with line
//                           items and stores the (aski → qbo) map.
//
// CONNECTION STATUS
//   * `get_my_qbo_status()` RPC returns whether the company has a
//     live connection. We surface that into a published @Bindable so
//     Settings can render "Connected to QuickBooks (realm 12345...)"
//     vs "Not connected".
//
// PER-INVOICE PUSH
//   InvoiceDetailView gets a "Push to QuickBooks" button gated on
//   `currentUserRole.canManageUsers`. The button always shows when
//   QBO is connected; the button shows "Update in QBO" when the
//   invoice already has a mapping, "Push to QBO" otherwise.

import Foundation
import Combine
import SwiftUI
import SafariServices
import Supabase
import Functions

@MainActor
final class QBOService: ObservableObject {

    static let shared = QBOService()
    private init() {}

    // MARK: - Status

    struct Status: Decodable, Equatable {
        let realm_id:        String?
        let is_active:       Bool?
        let connected_at:    String?
        let last_synced_at:  String?
        let last_error:      String?
        let access_valid:    Bool?

        var isConnected: Bool { (is_active ?? false) && realm_id != nil }
    }

    @Published var status: Status?
    @Published var isCheckingStatus = false

    /// Per-invoice mapping. Keyed on Aski invoice ID, value is the
    /// QBO numeric ID. Loaded by `refreshInvoiceMap()` whenever
    /// Settings or InvoiceDetailView appears so the UI knows whether
    /// to show "Push" vs "Update".
    @Published var invoiceQboIDs: [UUID: String] = [:]

    // MARK: - Errors

    enum QBOError: Error, LocalizedError {
        case notConfigured
        case notConnected
        case unauthorized
        case adminRequired
        case server(String)
        case transport(Error)
        case decoding

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "QuickBooks isn't activated for your company yet. Ask your admin to set up Intuit credentials in Supabase."
            case .notConnected:
                return "Connect to QuickBooks first from Settings → Integrations."
            case .unauthorized:
                return "Your session expired. Sign in again."
            case .adminRequired:
                return "Only admins can connect or push to QuickBooks."
            case .server(let m): return "QuickBooks error: \(m)"
            case .transport(let e): return "Network error: \(e.localizedDescription)"
            case .decoding: return "Couldn't read QuickBooks response."
            }
        }
    }

    // MARK: - Status fetch

    /// Reads the current company's QBO connection status. Safe for
    /// any role to call — server filters via `auth.uid()`.
    func refreshStatus() async {
        isCheckingStatus = true
        defer { isCheckingStatus = false }
        do {
            let rows: [Status] = try await supabase
                .rpc("get_my_qbo_status")
                .execute()
                .value
            status = rows.first
        } catch {
            // Leave previous status untouched on transport error so
            // banners don't flicker. The next manual refresh retries.
            status = status
        }
    }

    /// Pulls the (aski_invoice_id → qbo_id) map for the company so the
    /// UI can show "✓ in QBO" badges.
    func refreshInvoiceMap() async {
        struct Row: Decodable {
            let aski_id: UUID
            let qbo_id:  String
            let last_pushed_at: String?
        }
        struct P: Encodable { let p_table: String }
        do {
            let rows: [Row] = try await supabase
                .rpc("get_my_qbo_entity_ids", params: P(p_table: "invoices"))
                .execute()
                .value
            invoiceQboIDs = Dictionary(uniqueKeysWithValues: rows.map { ($0.aski_id, $0.qbo_id) })
        } catch {
            // Soft-fail: empty map means the UI just shows "Push" for everything.
            invoiceQboIDs = [:]
        }
    }

    // MARK: - Connect

    /// Mints the OAuth URL and returns it. Caller is expected to open
    /// the URL in a SafariSheet — when Intuit redirects back through
    /// `qbo-oauth-callback`, the success page deep-links the user back
    /// into the app.
    func connectURL() async throws -> URL {
        struct Empty: Encodable {}
        struct Resp: Decodable { let url: String }
        do {
            let resp: Resp = try await supabase.functions.invoke(
                "qbo-connect",
                options: FunctionInvokeOptions(
                    method: .post,
                    headers: ["Content-Type": "application/json"],
                    body: try JSONEncoder().encode(Empty())
                )
            )
            guard let u = URL(string: resp.url) else { throw QBOError.decoding }
            return u
        } catch let funcErr as FunctionsError {
            throw map(funcErr)
        } catch {
            throw QBOError.transport(error)
        }
    }

    // MARK: - Push invoice

    struct PushResult: Decodable {
        let qbo_id:        String
        let qbo_sync_token: String?
    }

    @discardableResult
    func pushInvoice(invoiceID: UUID) async throws -> PushResult {
        struct Params: Encodable { let invoice_id: String }
        do {
            let body = try JSONEncoder().encode(Params(invoice_id: invoiceID.uuidString))
            let resp: PushResult = try await supabase.functions.invoke(
                "qbo-push-invoice",
                options: FunctionInvokeOptions(
                    method: .post,
                    headers: ["Content-Type": "application/json"],
                    body: body
                )
            )
            // Update local map so the UI flips immediately.
            invoiceQboIDs[invoiceID] = resp.qbo_id
            return resp
        } catch let funcErr as FunctionsError {
            throw map(funcErr)
        } catch {
            throw QBOError.transport(error)
        }
    }

    // MARK: - Helpers

    /// Translate Supabase Functions errors to typed QBOError so views
    /// don't have to switch on raw HTTP codes.
    private func map(_ err: FunctionsError) -> QBOError {
        switch err {
        case .httpError(let code, let data):
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let msg = (body?["error"] as? String) ?? "HTTP \(code)"
            switch code {
            case 401: return .unauthorized
            case 403: return msg.lowercased().contains("admin") ? .adminRequired : .server(msg)
            case 412: return .notConnected
            case 503: return .notConfigured
            default:  return .server(msg)
            }
        case .relayError:
            return .server("Edge function relay error.")
        }
    }
}

// MARK: - QBO Connect Sheet

/// Sheet shown from Settings → Integrations → Connect to QuickBooks.
/// Hands the OAuth URL into a SafariSheet, then on dismissal pulls
/// the latest status to flip the UI to "Connected."
struct QBOConnectSheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var qbo = QBOService.shared

    @State private var url: URL?
    @State private var error: String?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if isLoading {
                    Spacer()
                    ProgressView("Preparing QuickBooks connection…")
                    Spacer()
                } else if let err = error {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 52)).foregroundColor(.orange)
                    Text("Couldn't open QuickBooks").font(.title3).bold()
                    Text(err).font(.subheadline).foregroundColor(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 32)
                    Button("Try again") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                    Spacer()
                } else if let url = url {
                    Spacer()
                    Image(systemName: "link.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.linearGradient(colors: [.green, .mint], startPoint: .top, endPoint: .bottom))
                    Text("Connect to QuickBooks").font(.title2).bold()
                    Text("You'll be sent to Intuit's secure consent page. After approving, you'll come back here automatically.")
                        .font(.subheadline).foregroundColor(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 32)
                    Spacer()
                    Link(destination: url) {
                        Label("Open QuickBooks Consent", systemImage: "arrow.up.right.square")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.purple)
                            .foregroundColor(.white)
                            .cornerRadius(14)
                    }
                    .padding(.horizontal, 24)
                    Text("Powered by Intuit OAuth")
                        .font(.caption2).foregroundColor(.secondary)
                        .padding(.bottom, 24)
                }
            }
            .navigationTitle("QuickBooks Online")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        Task {
                            await qbo.refreshStatus()
                            dismiss()
                        }
                    }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            url = try await qbo.connectURL()
        } catch let err as QBOService.QBOError {
            error = err.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Push Invoice Button (used inline in InvoiceDetailView)

/// Inline button — present this directly in the invoice's action
/// stack. Reads the cached map to decide between "Push" and "Update."
struct QBOPushInvoiceButton: View {
    let invoice: Invoice
    @ObservedObject private var qbo = QBOService.shared
    @State private var isPushing = false
    @State private var resultMessage: String?
    @State private var resultIsError = false

    private var alreadyMapped: Bool {
        qbo.invoiceQboIDs[invoice.id] != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Task { await push() }
            } label: {
                HStack {
                    if isPushing {
                        ProgressView().scaleEffect(0.85)
                        Text("Pushing to QuickBooks…")
                    } else {
                        Image(systemName: alreadyMapped ? "arrow.triangle.2.circlepath.circle.fill" : "square.and.arrow.up")
                        Text(alreadyMapped ? "Update in QuickBooks" : "Push to QuickBooks")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(red: 0.08, green: 0.46, blue: 0.07)) // Intuit green-ish
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .disabled(isPushing)

            if let msg = resultMessage {
                Label(msg, systemImage: resultIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(resultIsError ? .red : .green)
            }
        }
    }

    private func push() async {
        isPushing = true
        resultMessage = nil
        defer { isPushing = false }
        do {
            let r = try await QBOService.shared.pushInvoice(invoiceID: invoice.id)
            resultMessage = "Synced to QuickBooks (#\(r.qbo_id))."
            resultIsError = false
        } catch let err as QBOService.QBOError {
            resultMessage = err.errorDescription
            resultIsError = true
        } catch {
            resultMessage = error.localizedDescription
            resultIsError = true
        }
    }
}
