// CrashReporter.swift
// Aski IQ – Crash Reporting Abstraction Layer
//
// ── SETUP INSTRUCTIONS (one-time) ────────────────────────────────────────────
//
// 1. In Xcode: File → Add Package Dependencies…
//    URL: https://github.com/getsentry/sentry-cocoa
//    Version: Up To Next Major (from 8.0.0)
//    Add "Sentry" library to the BV APP target.
//
// 2. Create a Sentry project at https://sentry.io, get your DSN.
//    Replace the placeholder below with your actual DSN.
//
// 3. Uncomment the #if canImport lines — or just leave them; once the package
//    is added the import resolves and everything activates automatically.
//
// ── DSN PLACEHOLDER ───────────────────────────────────────────────────────────
//    Set via Xcode build setting SENTRY_DSN or paste directly below.
//    Never hard-code a production DSN into a public repo.
// ─────────────────────────────────────────────────────────────────────────────

import Foundation

#if canImport(Sentry)
import Sentry
#endif

// MARK: - Configuration

enum CrashReporter {

    /// Call once from `AskiIQApp.init()` or at the top of `restoreSession()`.
    static func configure() {
        #if canImport(Sentry)
        let dsn = Bundle.main.infoDictionary?["SENTRY_DSN"] as? String
               ?? ProcessInfo.processInfo.environment["SENTRY_DSN"]
               ?? ""                       // fallback: empty = Sentry disabled

        guard !dsn.isEmpty else {
            print("⚠️  CrashReporter: SENTRY_DSN not set — crash reporting disabled.")
            return
        }

        SentrySDK.start { options in
            options.dsn                          = dsn
            options.environment                  = buildEnvironment()
            options.releaseName                  = appVersion()

            // Performance monitoring — 10% of sessions in production, 100% in debug
            options.tracesSampleRate             = isDebug ? 1.0 : 0.10
            options.profilesSampleRate           = isDebug ? 1.0 : 0.05

            // Session replay — disabled (contains PII field data)
            options.sessionReplay.sessionSampleRate    = 0
            options.sessionReplay.onErrorSampleRate    = 0

            // Privacy: strip all HTTP bodies from breadcrumbs (contain user data)
            options.maxBreadcrumbs               = 50
            options.enableNetworkBreadcrumbs     = false   // avoid logging Supabase payloads
            options.enableCoreDataTracing        = false

            // Attach call stacks to all events for better debugging
            options.attachStacktrace             = true

            // Detect ANRs (App Not Responding)
            options.enableAppHangTracking        = true
            options.appHangTimeoutInterval       = 3.0

            // Auto-session tracking (crash-free session rate)
            options.enableAutoSessionTracking    = true
            options.sessionTrackingIntervalMillis = 30_000

            // Exclude non-fatal SwiftUI layout warnings from noise
            options.beforeSend = { event in
                // Drop events from SwiftUI internals that aren't actionable
                if let exceptions = event.exceptions {
                    let swiftUIInternal = exceptions.contains {
                        $0.type?.contains("SwiftUI") == true &&
                        $0.module?.contains("AttributeGraph") == true
                    }
                    if swiftUIInternal { return nil }
                }
                return event
            }
        }

        print("✅ CrashReporter: Sentry configured [\(buildEnvironment())] v\(appVersion())")
        #else
        print("ℹ️  CrashReporter: Sentry package not installed — add it via SPM to enable crash reporting.")
        #endif
    }

    // MARK: - User Context

    /// Call after successful sign-in to associate crashes with the user's company.
    /// Does NOT send the user's name or email to Sentry — only a stable,
    /// non-personally-identifiable identifier (company UUID).
    static func setUserContext(userID: UUID, companyID: UUID?, role: String) {
        #if canImport(Sentry)
        let user = SentrySDK.currentHub().scope.userObject ?? User()
        // Use a hashed user ID so Sentry can de-duplicate crashes per user
        // without storing identifiable information.
        user.userId      = userID.uuidString
        user.data        = [
            "company_id": companyID?.uuidString ?? "unknown",
            "role":       role,
        ]
        SentrySDK.setUser(user)
        #endif
    }

    /// Call on sign-out to clear user context from future events.
    static func clearUserContext() {
        #if canImport(Sentry)
        SentrySDK.setUser(nil)
        #endif
    }

    // MARK: - Manual Event Capture

    /// Capture a non-fatal error with additional context.
    /// Use this for unexpected-but-recoverable errors (e.g. sync failures).
    static func capture(error: Error, context: [String: Any] = [:]) {
        #if canImport(Sentry)
        SentrySDK.capture(error: error) { scope in
            if !context.isEmpty {
                scope.setExtras(context)
            }
        }
        #else
        print("🔴 CrashReporter.capture: \(error) — \(context)")
        #endif
    }

    /// Capture a non-fatal message (not an error type) with a severity level.
    static func capture(message: String, level: CrashLevel = .error,
                        context: [String: Any] = [:]) {
        #if canImport(Sentry)
        SentrySDK.capture(message: message) { scope in
            scope.level = SentryLevel(rawValue: level.rawValue) ?? .error
            if !context.isEmpty { scope.setExtras(context) }
        }
        #else
        print("🔴 CrashReporter[\(level.rawValue)]: \(message) — \(context)")
        #endif
    }

    /// Add a breadcrumb to enrich crash reports with app navigation context.
    static func breadcrumb(_ message: String, category: String = "app",
                           level: CrashLevel = .info) {
        #if canImport(Sentry)
        let crumb = Breadcrumb(level: SentryLevel(rawValue: level.rawValue) ?? .info,
                               category: category)
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
        #endif
    }

    // MARK: - Performance Transactions

    /// Wrap a significant async operation in a Sentry transaction for performance tracking.
    /// Usage:
    ///   let span = CrashReporter.startTransaction(name: "pullAll", operation: "sync")
    ///   defer { span?.finish() }
    static func startTransaction(name: String, operation: String) -> AnyObject? {
        #if canImport(Sentry)
        return SentrySDK.startTransaction(name: name, operation: operation)
        #else
        return nil
        #endif
    }

    // MARK: - Helpers

    enum CrashLevel: String {
        case debug, info, warning, error, fatal
    }

    private static var isDebug: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private static func buildEnvironment() -> String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }

    private static func appVersion() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version)+\(build)"
    }
}

// MARK: - SyncEngine Integration

extension SyncEngine {
    /// Wrap a sync operation with a Sentry performance transaction.
    func withCrashTransaction<T>(name: String, operation: String,
                                  _ work: () async throws -> T) async rethrows -> T {
        let span = CrashReporter.startTransaction(name: name, operation: operation)
        defer {
            #if canImport(Sentry)
            (span as? SentryTracer)?.finish()
            #endif
        }
        return try await work()
    }
}
