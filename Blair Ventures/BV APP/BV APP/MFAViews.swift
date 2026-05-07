// MFAViews.swift
// Aski IQ – Multi-Factor Authentication UI

import SwiftUI
import WebKit

// MARK: - 6-Digit OTP Input

struct OTPField: View {
    @Binding var code: String
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            // Hidden text field captures keyboard input
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .focused($focused)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .onChange(of: code) { _, new in
                    code = String(new.prefix(6).filter(\.isNumber))
                }

            HStack(spacing: 10) {
                ForEach(0..<6, id: \.self) { i in
                    let ch = code.count > i
                        ? String(code[code.index(code.startIndex, offsetBy: i)])
                        : ""
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                ch.isEmpty ? Color(.systemGray4) : Color.orange,
                                lineWidth: 2
                            )
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(.secondarySystemBackground))
                            )
                            .frame(width: 44, height: 52)
                        Text(ch)
                            .font(.title2).bold()
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
        }
        .onAppear { focused = true }
    }
}

// MARK: - MFA Challenge View
// Shown after password sign-in when the account has MFA enrolled.
// Caller supplies factorId + a completion that fires on success.

struct MFAChallengeView: View {
    let factorId: String
    let onSuccess: () async -> Void

    @State private var code        = ""
    @State private var isVerifying = false
    @State private var errorMsg: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {

                // Icon
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.12))
                        .frame(width: 80, height: 80)
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.orange)
                }
                .padding(.top, 40)

                VStack(spacing: 8) {
                    Text("Two-Factor Authentication")
                        .font(.title2).bold()
                    Text("Enter the 6-digit code from your authenticator app.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                OTPField(code: $code)
                    .padding(.horizontal, 24)

                if let err = errorMsg {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                        Text(err).font(.caption).foregroundColor(.red)
                    }
                    .padding(10)
                    .background(Color.red.opacity(0.08))
                    .cornerRadius(8)
                    .padding(.horizontal)
                }

                Button {
                    Task { await verify() }
                } label: {
                    ZStack {
                        if isVerifying {
                            ProgressView().tint(.white)
                        } else {
                            Text("Verify").font(.headline).foregroundColor(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(code.count == 6 ? Color.orange : Color.gray.opacity(0.4))
                    .cornerRadius(12)
                }
                .disabled(code.count < 6 || isVerifying)
                .padding(.horizontal, 24)

                Spacer()
            }
            .navigationTitle("Verification")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func verify() async {
        isVerifying = true
        errorMsg    = nil
        do {
            try await AuthService.verifyMFA(factorId: factorId, code: code)
            await onSuccess()
        } catch {
            errorMsg    = "Invalid code. Please try again."
            code        = ""
            isVerifying = false
        }
    }
}

// MARK: - MFA Enroll View
// Two-step: show QR + secret, then verify a code to confirm enrollment.

struct MFAEnrollView: View {
    let onEnrolled: () -> Void

    @State private var step: Step = .loading
    @State private var factorId   = ""
    @State private var qrDataURI  = ""
    @State private var secret     = ""
    @State private var code       = ""
    @State private var isBusy     = false
    @State private var errorMsg: String? = nil
    @Environment(\.dismiss) private var dismiss

    private enum Step { case loading, scan, verify, done }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .loading: loadingView
                case .scan:    scanView
                case .verify:  verifyView
                case .done:    doneView
                }
            }
            .navigationTitle("Set Up Authenticator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if step != .done {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .task { await startEnrollment() }
    }

    // MARK: Loading
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Generating setup code…")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Scan QR
    private var scanView: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("Scan this QR code with your authenticator app (Google Authenticator, Authy, 1Password, etc.).")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.top, 8)

                // QR code rendered via WKWebView
                QRWebView(dataURI: qrDataURI)
                    .frame(width: 220, height: 220)
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.08), radius: 8)

                VStack(spacing: 6) {
                    Text("Or enter this key manually:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(secret)
                        .font(.system(.caption, design: .monospaced)).bold()
                        .padding(8)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(8)
                        .textSelection(.enabled)
                }

                Button {
                    step = .verify
                } label: {
                    Text("I've Scanned the Code")
                        .font(.headline).foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.orange)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .padding(.top, 16)
        }
    }

    // MARK: Verify enrollment code
    private var verifyView: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 48))
                    .foregroundColor(.orange)
                    .padding(.top, 32)
                Text("Confirm Setup")
                    .font(.title2).bold()
                Text("Enter the 6-digit code from your authenticator app to confirm setup.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            OTPField(code: $code)
                .padding(.horizontal, 24)

            if let err = errorMsg {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                    Text(err).font(.caption).foregroundColor(.red)
                }
                .padding(10)
                .background(Color.red.opacity(0.08))
                .cornerRadius(8)
                .padding(.horizontal)
            }

            Button {
                Task { await confirmEnrollment() }
            } label: {
                ZStack {
                    if isBusy {
                        ProgressView().tint(.white)
                    } else {
                        Text("Confirm").font(.headline).foregroundColor(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(code.count == 6 ? Color.orange : Color.gray.opacity(0.4))
                .cornerRadius(12)
            }
            .disabled(code.count < 6 || isBusy)
            .padding(.horizontal, 24)

            Spacer()
        }
    }

    // MARK: Done
    private var doneView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)
            Text("Authenticator Enabled")
                .font(.title2).bold()
            Text("Your account is now protected with two-factor authentication.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button {
                onEnrolled()
                dismiss()
            } label: {
                Text("Done")
                    .font(.headline).foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.orange)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 24)
            Spacer()
        }
    }

    // MARK: Actions
    private func startEnrollment() async {
        do {
            let response = try await AuthService.enrollMFA()
            factorId   = response.factorId
            qrDataURI  = response.qrDataURI
            secret     = response.secret
            step       = .scan
        } catch {
            errorMsg = "Could not start setup. Please try again."
        }
    }

    private func confirmEnrollment() async {
        isBusy   = true
        errorMsg = nil
        do {
            try await AuthService.confirmMFAEnrollment(factorId: factorId, code: code)
            step = .done
        } catch {
            errorMsg = "Invalid code. Please try again."
            code     = ""
            isBusy   = false
        }
    }
}

// MARK: - MFA Disable Confirm View
// Requires the user to enter their current TOTP code before removing MFA.
// Prevents silent removal by someone with physical access to an unlocked device.

struct MFADisableConfirmView: View {
    let factorId: String
    let onDisabled: () -> Void

    @State private var code     = ""
    @State private var isBusy   = false
    @State private var errorMsg: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.10))
                        .frame(width: 80, height: 80)
                    Image(systemName: "lock.open.trianglebadge.exclamationmark")
                        .font(.system(size: 34))
                        .foregroundColor(.red)
                }
                .padding(.top, 40)

                VStack(spacing: 8) {
                    Text("Remove Two-Factor Auth?")
                        .font(.title2).bold()
                    Text("Enter the 6-digit code from your authenticator app to confirm. This removes MFA protection from your account.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                OTPField(code: $code).padding(.horizontal, 24)

                if let err = errorMsg {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                        Text(err).font(.caption).foregroundColor(.red)
                    }
                    .padding(10)
                    .background(Color.red.opacity(0.08))
                    .cornerRadius(8)
                    .padding(.horizontal)
                }

                Button(role: .destructive) {
                    Task { await disable() }
                } label: {
                    ZStack {
                        if isBusy { ProgressView().tint(.white) }
                        else {
                            Text("Remove Protection")
                                .font(.headline).foregroundColor(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(code.count == 6 ? Color.red : Color.gray.opacity(0.4))
                    .cornerRadius(12)
                }
                .disabled(code.count < 6 || isBusy)
                .padding(.horizontal, 24)

                Spacer()
            }
            .navigationTitle("Confirm Removal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func disable() async {
        isBusy = true; errorMsg = nil
        do {
            // Verify the code first — proves active possession of the authenticator
            try await AuthService.verifyMFA(factorId: factorId, code: code)
            try await AuthService.unenrollMFA(factorId: factorId)
            onDisabled()
            dismiss()
        } catch {
            errorMsg = "Invalid code. MFA was not removed."
            code = ""; isBusy = false
        }
    }
}

// MARK: - QR Code WebView
// Renders the data URI (SVG or PNG) returned by Supabase

private struct QRWebView: UIViewRepresentable {
    let dataURI: String

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.preferences.javaScriptEnabled = false
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.isOpaque        = false
        wv.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = false
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        let html = """
        <html>
        <head><meta name='viewport' content='width=device-width,initial-scale=1'></head>
        <body style='margin:0;padding:0;display:flex;justify-content:center;
                     align-items:center;background:white;width:100vw;height:100vh'>
          <img src='\(dataURI)' style='width:90vw;height:90vw;max-width:200px;max-height:200px'>
        </body></html>
        """
        wv.loadHTMLString(html, baseURL: nil)
    }
}
