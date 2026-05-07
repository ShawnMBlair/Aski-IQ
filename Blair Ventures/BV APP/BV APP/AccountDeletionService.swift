// AccountDeletionService.swift
// Aski IQ — PIPEDA / GDPR right-to-erasure pair to DataExportService.
//
// WHY THIS EXISTS
// PIPEDA, GDPR, and Apple App Store guideline 5.1.1(v) all require that an
// app supporting account creation also supports account deletion from
// within the app. Sign-out is not enough — the user has to be able to
// permanently revoke their account.
//
// FLOW
//   1. User opens AccountDeletionView from Settings → Privacy.
//   2. We show a clear warning + offer to download their data first.
//   3. User re-authenticates with their password (defense-in-depth so a
//      hijacked unlocked phone can't nuke an account in one tap).
//   4. We call the `delete-account` Edge Function (verify_jwt:true), which
//      anonymizes their `profiles` + `employees` rows, writes an audit
//      log entry, and hard-deletes the auth.users row using the service-
//      role key on the server side.
//   5. We sign out locally and clear all cached data; the auth state
//      flips back to the sign-in screen.
//
// WHAT THE SERVER PRESERVES
//   Business records that legally must be retained — timesheets, incidents,
//   change orders, invoices — stay in place. The user's PII fields on
//   `profiles` and `employees` are scrubbed; auth.users is hard-deleted so
//   they cannot sign back in.
//
// USAGE
//   let result = await AccountDeletionService.shared.deleteAccount(
//       password:       "their_current_password",
//       reason:         optionalUserNote,
//       exportedFirst:  true
//   )
//   switch result {
//   case .success:               // store.clearAllData() + sign-out flip
//   case .failure(let err):      // show err.userMessage
//   }

import Foundation
import Supabase
import Functions

@MainActor
final class AccountDeletionService {

    static let shared = AccountDeletionService()
    private init() {}

    enum DeletionError: Error, LocalizedError {
        case notSignedIn
        case missingEmail
        case reauthFailed(String)
        case serverError(String)
        case partial(String)
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Sign in before requesting account deletion."
            case .missingEmail:
                return "Account has no email on file. Contact support to delete."
            case .reauthFailed(let m):
                return "Password didn't match: \(m)"
            case .serverError(let m):
                return "Couldn't delete account: \(m)"
            case .partial(let m):
                return "Partial failure — please contact support: \(m)"
            case .transport(let e):
                return "Network error: \(e.localizedDescription)"
            }
        }

        /// User-facing copy that prefers `errorDescription` but falls back
        /// to a generic message if it's nil.
        var userMessage: String {
            errorDescription ?? "Couldn't delete account. Please try again."
        }
    }

    /// Performs the full deletion flow: re-auth, server-side erasure, sign-out.
    /// On success the caller should also call `store.clearAllData()` —
    /// `RootView`'s auth-state listener will flip back to the sign-in screen.
    func deleteAccount(
        store:          AppStore,
        password:       String,
        reason:         String?,
        exportedFirst:  Bool
    ) async -> Result<Void, DeletionError> {
        guard let user = store.currentUser else { return .failure(.notSignedIn) }
        guard let email = user.email, !email.isEmpty else { return .failure(.missingEmail) }

        // 1. Re-auth: verify the password by signing in fresh. Supabase
        //    doesn't expose a "verify password" endpoint, but a successful
        //    signIn proves the password is correct without disrupting the
        //    existing session in any user-visible way.
        do {
            _ = try await supabase.auth.signIn(email: email, password: password)
        } catch {
            return .failure(.reauthFailed(error.localizedDescription))
        }

        // 2. Call the Edge Function. It handles anonymization, audit log,
        //    and hard-deletes the auth.users row. After this call returns
        //    success the JWT we hold is for a user that no longer exists,
        //    so any further Supabase request will 401 — which is fine,
        //    we sign out next anyway.
        var payload: [String: Any] = [
            "exported_first": exportedFirst
        ]
        if let r = reason, !r.isEmpty { payload["reason"] = r }

        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            try await supabase.functions.invoke(
                "delete-account",
                options: FunctionInvokeOptions(
                    method: .post,
                    headers: ["Content-Type": "application/json"],
                    body: body
                )
            )
        } catch let funcErr as FunctionsError {
            switch funcErr {
            case .httpError(let code, let data):
                let msg = extractErrorMessage(from: data)
                // 500 + "partial" body means PII got scrubbed but auth
                // delete failed — safer to surface that explicitly so the
                // user knows to contact support rather than retry blindly.
                if code == 500, isPartialFailure(data) {
                    return .failure(.partial(msg))
                }
                return .failure(.serverError(msg))
            case .relayError:
                return .failure(.serverError("Edge Function relay error."))
            }
        } catch {
            return .failure(.transport(error))
        }

        // 3. Sign out client-side. The auth.users row is gone server-side,
        //    so sign-out is mostly to clear the local session token.
        try? await supabase.auth.signOut()

        return .success(())
    }

    // MARK: - Helpers

    private func extractErrorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = json["error"] as? String {
            return msg
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }

    private func isPartialFailure(_ data: Data) -> Bool {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["partial"] as? Bool == true {
            return true
        }
        return false
    }
}
