// BV_APPApp.swift
// AskiCommand – App Entry Point
// REPLACES your existing BV_APPApp.swift

import SwiftUI
import Supabase
import BackgroundTasks

@main
struct AskiIQApp: App {
    @StateObject private var store          = AppStore.shared
    @StateObject private var syncEngine     = SyncEngine.shared
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @StateObject private var onboardingPresenter = OnboardingPresenter.shared
    @State private var isRestoringSession   = true
    @Environment(\.scenePhase) private var scenePhase

    /// Identifier registered for periodic background sync. Must match the
    /// matching `BGTaskSchedulerPermittedIdentifiers` entry in Info.plist
    /// once the user adds it (a user-side step — see audit roadmap Phase 1).
    private static let backgroundSyncTaskID = "ca.askiiq.bg-sync"

    init() {
        // Build proof — fires once on launch. If you don't see this line
        // in the Xcode console, the binary on the device/simulator is
        // stale and the latest code is not actually running. Used for
        // triaging the tenant-isolation reports during May 2026.
        let info = Bundle.main.infoDictionary
        let shortVersion = (info?["CFBundleShortVersionString"] as? String) ?? "unknown"
        let buildNumber  = (info?["CFBundleVersion"]            as? String) ?? "unknown"
        let bundleID     = Bundle.main.bundleIdentifier                     ?? "unknown"
        print("🧪 BUILD VERSION: \(shortVersion) (\(buildNumber)) bundle=\(bundleID)")

        CrashReporter.configure()
        // Phase 1 Step 1: install role-decode diagnostic. Replaces the
        // silent `print` in UserRole.init(from:) with a CrashReporter
        // capture + dev-menu observation buffer so unknown server roles
        // surface immediately instead of silently demoting users to
        // .fieldWorker. Must run AFTER CrashReporter.configure() so the
        // Sentry pipeline is ready.
        RoleProbe.install()
        registerBackgroundTasks()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if isRestoringSession {
                    // Loading screen while checking for existing session
                    ZStack {
                        Color(.systemGroupedBackground).ignoresSafeArea()
                        VStack(spacing: 16) {
                            Image(systemName: "bolt.shield.fill")
                                .font(.system(size: 52))
                                .foregroundColor(.purple)
                            ProgressView()
                        }
                    }
                } else if store.isAuthenticated {
                    RootView()
                        .environmentObject(store)
                        .environmentObject(syncEngine)
                        .environmentObject(networkMonitor)
                        .overlay(ToastHost())
                        // First-run setup wizard. Presenter decides
                        // whether to actually show it (admin role +
                        // empty tenant + not previously completed).
                        .sheet(isPresented: $onboardingPresenter.isPresented) {
                            OnboardingWizardView()
                                .environmentObject(store)
                                .interactiveDismissDisabled()
                        }
                        .onAppear {
                            onboardingPresenter.evaluate(in: store)
                        }
                        .safeAreaInset(edge: .top, spacing: 0) {
                            // safeAreaInset content does NOT inherit environment
                            // objects from modifiers above it — re-inject them
                            // explicitly so FailedSyncBanner / OfflineBanner can
                            // resolve `@EnvironmentObject var store: AppStore`.
                            // Without this the app fatal-crashes on launch as
                            // soon as FailedSyncBanner reads `store.totalFailedSyncCount`.
                            VStack(spacing: 0) {
                                OfflineBanner(isVisible: !networkMonitor.isConnected)
                                FailedSyncBanner()
                            }
                            .environmentObject(store)
                            .environmentObject(syncEngine)
                            .environmentObject(networkMonitor)
                        }
                        .animation(.easeInOut(duration: 0.3), value: networkMonitor.isConnected)
                        .animation(.easeInOut(duration: 0.3), value: store.totalFailedSyncCount)
                } else {
                    LoginView()
                        .environmentObject(store)
                }
            }
            .task {
                await restoreSession()
                NotificationManager.shared.requestAuthorization()
                // Handle external session revocation (admin force-logout, token expiry)
                for await state in supabase.auth.authStateChanges {
                    if state.event == .signedOut && store.isAuthenticated {
                        // Auth-state listener safety net — fires when the
                        // server revokes the session (admin force-logout,
                        // token expiry, password change). Hard reset so
                        // the next sign-in starts from a clean slate.
                        await MainActor.run { store.fullSignOutReset() }
                    }
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                handleScenePhase(newPhase)
            }
        }
    }

    // MARK: - Lifecycle

    /// Foreground: pull fresh server state and reconcile overdue invoices so
    /// the user does not see stale numbers after the app sat in background.
    /// Background: schedule the next periodic sync window.
    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            guard store.isAuthenticated, !isRestoringSession else { return }
            Task { await store.refreshAll() }
        case .background:
            scheduleNextBackgroundSync()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Background tasks

    /// Registers the BGAppRefreshTask handler at launch. The handler runs
    /// `pushPending()` every wake-up to flush queued local edits, and
    /// — when the cached snapshot is older than `staleThresholdSeconds`
    /// — also runs `pullAll()` so a phone left in a truck overnight
    /// doesn't push 24h-old state on top of intervening server writes.
    ///
    /// 2026-04 re-audit fix #2: pre-fix only push ran in the
    /// background, so devices offline >15min would happily push stale
    /// data the moment connectivity returned without ever reconciling
    /// concurrent server-side edits.
    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundSyncTaskID,
            using: nil
        ) { task in
            handleBackgroundSync(task: task as! BGAppRefreshTask)
        }
    }

    /// Anything older than this and the BG handler runs a full pull
    /// instead of just push. 1 hour balances: (a) we don't want to
    /// burn 30s of BG budget on a pull every 15 min when the user is
    /// actively using the app, (b) we DO want to recover after a
    /// long offline gap.
    private static let staleThresholdSeconds: TimeInterval = 3_600

    private func handleBackgroundSync(task: BGAppRefreshTask) {
        // Always schedule the *next* run so the cycle continues.
        scheduleNextBackgroundSync()

        let work = Task { @MainActor in
            // Stale-snapshot detection: if the last successful pull is
            // older than the threshold, refresh first. Push happens
            // either way at the end so queued local edits never sit.
            let lastPull = SyncEngine.shared.lastSyncAt ?? .distantPast
            let staleness = Date().timeIntervalSince(lastPull)
            let needsPull = staleness > Self.staleThresholdSeconds

            if needsPull,
               let user = AppStore.shared.currentUser,
               !AppStore.shared.isOfflineMode {
                // Best-effort pull. Time budget for BGAppRefreshTask
                // is ~30s — pullAll has historically run in well under
                // that even with full datasets, but if iOS kills us
                // the expirationHandler below cleans up gracefully.
                await SyncEngine.shared.pullAll(
                    for:  user.id,
                    role: AppStore.shared.currentUserRole
                )
            }

            await SyncEngine.shared.pushPending()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    /// Asks iOS to wake us no sooner than 15 minutes from now. iOS may push
    /// the actual fire time well beyond that based on usage patterns and
    /// power state — that's fine, this is a best-effort path.
    private func scheduleNextBackgroundSync() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundSyncTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // BGTaskScheduler refuses if Info.plist's BGTaskSchedulerPermittedIdentifiers
            // does not include this identifier. That's a user-side config step;
            // failing here is harmless — sync still happens on foreground.
        }
    }

    // MARK: - Session Restore

    private func wipeLegacyLocalData() {
        // ⚠ CRITICAL FIX 2026-04-28
        // The previous list included every active `bv_*` key, which meant any
        // event that cleared the `bv_legacy_wiped` flag (Xcode reinstall, sim
        // reset, manual delete) would wipe ALL the user's current local data
        // on next launch. Reduced to ONLY the truly legacy AskiCommand-era
        // keys (`ak_*`) and the long-since-retired BlairVentures_Store.json
        // file. Anything `bv_*` is current and must NEVER appear here.
        let legacyKeys = ["ak_clients", "ak_quotes"]
        guard UserDefaults.standard.bool(forKey: "bv_legacy_wiped") == false else { return }
        for key in legacyKeys { UserDefaults.standard.removeObject(forKey: key) }
        // Delete the old JSON store file if present (pre-Supabase architecture)
        if let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: docDir.appendingPathComponent("BlairVentures_Store.json"))
        }
        UserDefaults.standard.set(true, forKey: "bv_legacy_wiped")
    }

    private func restoreSession() async {
        wipeLegacyLocalData()
        if let profile = await AuthService.restoreSession() {

            // ── Tenant guard ─────────────────────────────────────────
            // Mirror of the LoginView guard. A restored profile MUST
            // carry a companyID; otherwise the app would launch with
            // no tenant scope and the SyncEngine would either pull
            // nothing (fail-safe) or — worse — fall back to a stale
            // value. Force a clean sign-out instead.
            guard let companyID = profile.companyID else {
                #if DEBUG
                assertionFailure("Restored profile has no company_id — wiping session. user=\(profile.id) email=\(profile.email)")
                #endif
                print("⛔ RESTORE GUARD: profile.companyID is nil — wiping session for \(profile.email)")
                try? await AuthService.signOut()
                await MainActor.run {
                    store.fullSignOutReset()
                    isRestoringSession = false
                }
                return
            }

            // Debug telemetry — temporary; remove once tenant switching
            // is confirmed stable.
            print("🔓 RESTORE → user=\(profile.id) email=\(profile.email) company_id=\(companyID) role=\(profile.role.rawValue)")

            var user = Employee(
                firstName: profile.fullName.components(separatedBy: " ").first ?? "",
                lastName:  profile.fullName.components(separatedBy: " ").dropFirst().joined(separator: " ")
            )
            user.id    = profile.id
            user.email = profile.email
            user.role  = profile.role

            await MainActor.run {
                // Defensive cache clear — mirrors LoginView.completeLogin.
                // On launch the @Published arrays should already be empty
                // (no loadFromDisk runs for tenant data), but if a future
                // change introduces persisted caches, this guarantees a
                // clean slate before we establish tenant scope.
                store.clearAllData()

                store.currentUser      = user
                store.currentUserRole  = profile.role
                store.currentCompanyID = companyID  // unwrapped non-optional
                store.isAuthenticated  = true

                // Phase 1 Step 3: attach LocalPendingStore + replay any
                // pending rows surviving from before app termination.
                // Must run AFTER currentCompanyID is set.
                store.bindLocalPersistence(companyID: companyID)
            }

            // Set anonymised crash-reporter context (company ID + role only, no PII)
            CrashReporter.setUserContext(
                userID:    profile.id,
                companyID: companyID,
                role:      profile.role.rawValue
            )

            Task {
                // Sync guard — see comment in LoginView.completeLogin.
                // Re-check store state at fire time so this Task can never
                // pull against a stale or missing companyID.
                guard let activeCompanyID = await store.currentCompanyID else {
                    print("⛔ SYNC BLOCKED — missing company_id (restore Task)")
                    return
                }
                print("🔄 SYNC → pulling for company_id=\(activeCompanyID)")
                await AppSettings.shared.loadForCompany(activeCompanyID)
                await SyncEngine.shared.pullAll(for: profile.id, role: profile.role)
            }
        }

        await MainActor.run {
            isRestoringSession = false
        }
    }
}
