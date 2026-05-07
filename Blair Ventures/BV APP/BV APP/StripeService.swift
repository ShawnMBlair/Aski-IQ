// StripeService.swift
// Aski IQ — Stripe Checkout integration for invoice payments (Tier A).
//
// FLOW
//   1. iOS calls `createCheckoutSession(forInvoiceID:)`. We hit the
//      `stripe-checkout` Edge Function (deployed v1) which:
//         - Verifies the caller's company owns the invoice
//         - Computes balance_due in cents
//         - Creates a Stripe Checkout Session with one line item
//         - Returns the hosted Checkout URL
//   2. We open the URL in SFSafariViewController so the customer pays
//      against Stripe's own UI (no PCI exposure for us).
//   3. Stripe fires `checkout.session.completed` → the
//      `stripe-webhook` Edge Function records the payment via
//      `record_invoice_stripe_payment` RPC.
//   4. Next pull picks up the updated `invoices.payments` JSON +
//      `status = 'paid'` and the UI reflects it.
//
// SECRETS
// The user must configure `STRIPE_SECRET_KEY` and
// `STRIPE_WEBHOOK_SECRET` as Supabase Edge Function secrets before
// any of this works. Until then, `createCheckoutSession` returns
// `.notConfigured` and the UI shows a friendly "ask your admin"
// message instead of a generic 5xx.
//
// WHY NO STRIPE SDK
// The `stripe-checkout` Edge Function returns a hosted URL —
// SFSafariViewController is enough. Adding StripeKit / Stripe iOS
// SDK would pull a 50MB+ binary for a feature most users hit twice
// a month. We can revisit if we need Apple Pay / native card sheets.

import Foundation
import SwiftUI
import SafariServices

@MainActor
final class StripeService {

    static let shared = StripeService()
    private init() {}

    // MARK: - Result Models

    /// Mirrors the JSON shape returned by `stripe-checkout`.
    struct CheckoutSession: Decodable {
        let url:          String
        let session_id:   String
        let amount_cents: Int
        let currency:     String

        var amountFormatted: String {
            let dollars = Double(amount_cents) / 100.0
            let f = NumberFormatter()
            f.numberStyle = .currency
            f.currencyCode = currency.uppercased()
            return f.string(from: NSNumber(value: dollars)) ?? "\(dollars)"
        }
    }

    enum CheckoutError: Error, LocalizedError {
        case notConfigured
        case invoiceAlreadyPaid
        case invoiceVoid
        case noBalanceOwing
        case unauthorized
        case server(String)
        case transport(Error)
        case decoding

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Online payments aren't activated for your company yet. Ask your admin to set Stripe up."
            case .invoiceAlreadyPaid:
                return "This invoice is already paid."
            case .invoiceVoid:
                return "This invoice is voided."
            case .noBalanceOwing:
                return "This invoice has no balance owing."
            case .unauthorized:
                return "Your session expired. Sign in again."
            case .server(let m):
                return "Stripe checkout error: \(m)"
            case .transport(let e):
                return "Network error: \(e.localizedDescription)"
            case .decoding:
                return "Couldn't read the payment session response."
            }
        }
    }

    // MARK: - Create Checkout Session

    /// Hits the `stripe-checkout` Edge Function and returns the hosted
    /// payment URL. Caller is expected to open it in
    /// `SFSafariViewController` (or `UIApplication.shared.open`).
    func createCheckoutSession(forInvoiceID invoiceID: UUID) async throws -> CheckoutSession {
        // Build request manually — same pattern AIProxyClient uses for
        // streaming. Keeps our Edge Function calls consistent and
        // doesn't depend on the SDK's typed invoke for a small payload.
        let url = supabaseFunctionsBaseURL.appendingPathComponent("stripe-checkout")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(supabasePublicAnonKey, forHTTPHeaderField: "apikey")

        let token: String
        do {
            token = try await AuthService.currentAccessToken()
        } catch {
            throw CheckoutError.unauthorized
        }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = ["invoice_id": invoiceID.uuidString]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await dataTask(req)
        guard let http = response as? HTTPURLResponse else {
            throw CheckoutError.server("No HTTP response")
        }

        // 2xx → decode CheckoutSession
        if (200...299).contains(http.statusCode) {
            do {
                return try JSONDecoder().decode(CheckoutSession.self, from: data)
            } catch {
                throw CheckoutError.decoding
            }
        }

        // Non-2xx → look for our typed error envelope and map status
        // codes to typed errors so the UI can render specific copy.
        let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let errMsg = (envelope?["error"] as? String) ?? "HTTP \(http.statusCode)"

        switch http.statusCode {
        case 401: throw CheckoutError.unauthorized
        case 503: throw CheckoutError.notConfigured
        case 409:
            // 409 is used for already-paid / void / no balance.
            if errMsg.lowercased().contains("already paid") { throw CheckoutError.invoiceAlreadyPaid }
            if errMsg.lowercased().contains("voided")       { throw CheckoutError.invoiceVoid }
            if errMsg.lowercased().contains("no balance")   { throw CheckoutError.noBalanceOwing }
            throw CheckoutError.server(errMsg)
        default:
            throw CheckoutError.server(errMsg)
        }
    }

    /// Convenience wrapper that wraps URLSession's bytes API into
    /// the simpler Data + Response form. We don't use streaming for
    /// the Stripe checkout call — it's a fast one-shot.
    private func dataTask(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: req)
        } catch {
            throw CheckoutError.transport(error)
        }
    }
}

// MARK: - SafariView (presented via .sheet)

/// Wraps SFSafariViewController so we can hand a Checkout URL straight
/// into a SwiftUI `.sheet` without dropping out to UIKit boilerplate
/// at every call site. Shared with QuickBooks OAuth + HelloSign flows
/// later — same shape applies.
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let cfg = SFSafariViewController.Configuration()
        cfg.entersReaderIfAvailable = false
        let vc = SFSafariViewController(url: url, configuration: cfg)
        // `preferredControlTintColor` was deprecated in iOS 26 because
        // tinting the controls clashes with the system's background
        // effects on the Safari toolbar. The default tint already
        // looks correct against our purple-leaning UI, so we leave
        // it alone — no functional regression.
        return vc
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

// MARK: - Pay-with-Stripe Sheet (used from InvoiceDetailView)

/// Presented when the user taps "Pay Online" on an invoice. Three
/// states:
///   1. Loading — calling the Edge Function
///   2. Loaded  — show "Open Stripe Checkout" button + amount
///   3. Error   — show the typed error with a Retry
struct StripeCheckoutSheet: View {
    let invoice: Invoice
    @Environment(\.dismiss) var dismiss

    @State private var session: StripeService.CheckoutSession?
    @State private var error: String?
    @State private var isLoading = true
    @State private var showSafari = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if isLoading {
                    Spacer()
                    ProgressView("Setting up secure payment…")
                        .controlSize(.large)
                    Spacer()
                } else if let err = error {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 52))
                        .foregroundColor(.orange)
                    Text("Couldn't open checkout")
                        .font(.title3).bold()
                    Text(err)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button {
                        Task { await load() }
                    } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.purple)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .padding(.horizontal, 24)
                    Spacer()
                } else if let s = session {
                    Spacer()
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.linearGradient(colors: [.purple, .blue], startPoint: .top, endPoint: .bottom))

                    VStack(spacing: 6) {
                        Text("Pay \(s.amountFormatted)")
                            .font(.largeTitle).bold()
                        Text("Invoice \(invoice.invoiceNumber)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Text("Tap below to open Stripe's secure checkout. Your card details never touch our servers.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Spacer()

                    Button {
                        showSafari = true
                    } label: {
                        Label("Open Stripe Checkout", systemImage: "creditcard.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.purple)
                            .foregroundColor(.white)
                            .cornerRadius(14)
                    }
                    .padding(.horizontal, 24)

                    Text("Powered by Stripe")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 24)
                }
            }
            .navigationTitle("Online Payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await load()
            }
            .sheet(isPresented: $showSafari, onDismiss: { dismiss() }) {
                if let urlStr = session?.url, let url = URL(string: urlStr) {
                    SafariSheet(url: url)
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            session = try await StripeService.shared.createCheckoutSession(forInvoiceID: invoice.id)
        } catch let err as StripeService.CheckoutError {
            error = err.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}
