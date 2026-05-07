// LoginView.swift
// Aski IQ – Authentication Gate

import SwiftUI

struct LoginView: View {
    @EnvironmentObject var store: AppStore

    @State private var email           = ""
    @State private var password        = ""
    @State private var fullName        = ""
    @State private var companyName     = ""
    @State private var inviteCode      = ""
    @State private var useInviteCode   = false
    @State private var isSigningUp     = false
    @State private var isLoading       = false
    @State private var errorMessage: String? = nil
    @State private var mfaFactorId: String? = nil
    @State private var pendingProfile: AppUserProfile? = nil
    @FocusState private var focusedField: Field?

    private enum Field { case email, password, fullName, companyName }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {

                // MARK: - Branding Header
                VStack(spacing: 16) {
                    Image("AskiIQIconMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 110, height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 4)

                    VStack(spacing: 4) {
                        Text("ASKI IQ")
                            .font(.system(size: 32, weight: .heavy, design: .default))
                            .tracking(3)
                            .foregroundColor(.primary)

                        Text("Smart Field Operations.")
                            .font(.caption.weight(.semibold))
                            .tracking(1)
                            .foregroundColor(AskiColor.brandAccent)

                        Text("Grounded in the Land.")
                            .font(.caption.weight(.semibold))
                            .tracking(1)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 72)
                .padding(.bottom, 48)

                // MARK: - Login / Sign Up Card
                VStack(spacing: 20) {

                    // Mode toggle
                    Picker("Mode", selection: $isSigningUp) {
                        Text("Sign In").tag(false)
                        Text("Create Account").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: isSigningUp) { errorMessage = nil }

                    // Sign-up only fields
                    if isSigningUp {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Full Name", systemImage: "person.fill")
                                .font(.caption).bold().foregroundColor(.secondary)
                            TextField("Shawn Blair", text: $fullName)
                                .textContentType(.name)
                                .autocapitalization(.words)
                                .focused($focusedField, equals: .fullName)
                                .padding(12)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(10)
                        }

                        // Invite code toggle
                        Toggle(isOn: $useInviteCode.animation()) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Join an existing company")
                                    .font(.subheadline).foregroundColor(.primary)
                                Text("Use an invite code from your admin")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .onChange(of: useInviteCode) {
                            companyName = ""
                            inviteCode  = ""
                        }

                        if useInviteCode {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Invite Code", systemImage: "person.badge.key.fill")
                                    .font(.caption).bold().foregroundColor(.secondary)
                                TextField("e.g. A1B2C3D4", text: $inviteCode)
                                    .autocapitalization(.allCharacters)
                                    .disableAutocorrection(true)
                                    .focused($focusedField, equals: .companyName)
                                    .padding(12)
                                    .background(Color(.secondarySystemBackground))
                                    .cornerRadius(10)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Company Name", systemImage: "building.2.fill")
                                    .font(.caption).bold().foregroundColor(.secondary)
                                TextField("Aski IQ", text: $companyName)
                                    .autocapitalization(.words)
                                    .focused($focusedField, equals: .companyName)
                                    .padding(12)
                                    .background(Color(.secondarySystemBackground))
                                    .cornerRadius(10)
                            }
                        }
                    }

                    // Email field
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Email", systemImage: "envelope.fill")
                            .font(.caption).bold().foregroundColor(.secondary)
                        TextField("you@example.com", text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .focused($focusedField, equals: .email)
                            .padding(12)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(10)
                    }

                    // Password field
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Password", systemImage: "lock.fill")
                            .font(.caption).bold().foregroundColor(.secondary)
                        SecureField(isSigningUp ? "Choose a password" : "Enter your password", text: $password)
                            .textContentType(isSigningUp ? .newPassword : .password)
                            .focused($focusedField, equals: .password)
                            .padding(12)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(10)
                    }

                    // Error message
                    if let error = errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                            Text(error).font(.caption).foregroundColor(.red)
                        }
                        .padding(10)
                        .background(Color.red.opacity(0.08))
                        .cornerRadius(8)
                    }

                    // Primary action button
                    Button {
                        focusedField = nil
                        Task { isSigningUp ? await signUp() : await signIn() }
                    } label: {
                        ZStack {
                            if isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Text(isSigningUp ? "Create Account" : "Sign In")
                                    .font(.headline).foregroundColor(.white)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(canProceed ? Color.orange : Color.gray.opacity(0.5))
                        .cornerRadius(12)
                    }
                    .disabled(!canProceed || isLoading)

                    if isSigningUp {
                        Text(useInviteCode
                             ? "Your role will be assigned by your invite code."
                             : "Your account will be set up as a Manager. An admin can adjust roles in Settings.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }

                }
                .padding(AskiSpacing.xxl)
                .background(
                    RoundedRectangle(cornerRadius: AskiRadius.hero, style: .continuous)
                        .fill(Color(.systemBackground))
                        .shadow(color: .black.opacity(0.10), radius: 24, x: 0, y: 8)
                        .shadow(color: .black.opacity(0.04), radius: 2,  x: 0, y: 1)
                )
                .padding(.horizontal, AskiSpacing.xxl)

                Spacer(minLength: AskiSpacing.xxxl)

                Text("© \(currentYear) Aski IQ")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.bottom, AskiSpacing.xxl)
            }
        }
        .background(loginBackground)
        .onAppear {
            // Autofocus the first field so the keyboard appears immediately
            // and VoiceOver lands on the email input on first launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if focusedField == nil {
                    focusedField = isSigningUp ? .fullName : .email
                }
            }
        }
        .sheet(item: Binding(
            get: { mfaFactorId.map { MFAFactorItem(id: $0) } },
            set: { if $0 == nil { mfaFactorId = nil; isLoading = false } }
        )) { item in
            MFAChallengeView(factorId: item.id) {
                await MainActor.run { mfaFactorId = nil }
                if let profile = pendingProfile { await completeLogin(profile: profile) }
            }
            .interactiveDismissDisabled()
        }
        .onSubmit {
            if focusedField == .email {
                focusedField = .password
            } else if canProceed {
                Task { isSigningUp ? await signUp() : await signIn() }
            }
        }
    }

    // MARK: - Helpers

    private var canProceed: Bool {
        let e = email.trimmingCharacters(in: .whitespaces)
        if isSigningUp {
            let nameOk = !fullName.trimmingCharacters(in: .whitespaces).isEmpty
            let thirdOk = useInviteCode
                ? !inviteCode.trimmingCharacters(in: .whitespaces).isEmpty
                : !companyName.trimmingCharacters(in: .whitespaces).isEmpty
            return !e.isEmpty && !password.isEmpty && nameOk && thirdOk
        }
        return !e.isEmpty && !password.isEmpty
    }

    private var currentYear: String {
        String(Calendar.current.component(.year, from: Date()))
    }

    /// Subtle brand-tinted gradient that frames the login card. Adapts to dark
    /// mode automatically because both ends compose with system surface colors.
    /// Replaces the previous flat `systemGroupedBackground`.
    private var loginBackground: some View {
        ZStack {
            Color(.systemGroupedBackground)
            LinearGradient(
                colors: [
                    AskiColor.brandAccent.opacity(0.18),
                    AskiColor.brandAccent.opacity(0.04),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint:   .bottomTrailing
            )
            // Soft radial spotlight behind the brand mark
            RadialGradient(
                colors: [AskiColor.brandAccent.opacity(0.22), .clear],
                center: .init(x: 0.5, y: 0.18),
                startRadius: 20,
                endRadius:   240
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Sign Up

    private func signUp() async {
        isLoading = true; errorMessage = nil
        do {
            let profile: AppUserProfile
            if useInviteCode {
                profile = try await AuthService.signUpWithInvite(
                    email:    email.trimmingCharacters(in: .whitespaces),
                    password: password,
                    fullName: fullName.trimmingCharacters(in: .whitespaces),
                    code:     inviteCode.trimmingCharacters(in: .whitespaces)
                )
            } else {
                profile = try await AuthService.signUp(
                    email:       email.trimmingCharacters(in: .whitespaces),
                    password:    password,
                    fullName:    fullName.trimmingCharacters(in: .whitespaces),
                    companyName: companyName.trimmingCharacters(in: .whitespaces)
                )
            }
            await completeLogin(profile: profile)
        } catch {
            await MainActor.run {
                isLoading    = false
                errorMessage = friendlySignUpError(error)
            }
        }
    }

    // MARK: - Sign In

    private func signIn() async {
        isLoading    = true
        errorMessage = nil

        do {
            let profile = try await AuthService.signIn(
                email: email.trimmingCharacters(in: .whitespaces),
                password: password
            )

            // Check if MFA challenge is required before granting access
            if await AuthService.mfaChallengeRequired(),
               let factorId = await AuthService.mfaFactorID() {
                await MainActor.run {
                    pendingProfile = profile
                    mfaFactorId    = factorId
                    // isLoading stays true — sheet dismissal resets it
                }
                return
            }

            await completeLogin(profile: profile)

        } catch {
            await MainActor.run {
                isLoading    = false
                errorMessage = friendlyError(error)
            }
        }
    }

    private func completeLogin(profile: AppUserProfile) async {
        // ── Tenant guard ─────────────────────────────────────────────
        // The app must NEVER load with a missing companyID. If the
        // signup chain failed (RPC error, slow trigger, race), the
        // profile may come back with `companyID == nil`. Refuse to
        // proceed: clear auth state, surface the error, force the
        // user to retry rather than silently inheriting a previous
        // session's `currentCompanyID` and seeing the wrong tenant's
        // data.
        guard let companyID = profile.companyID else {
            #if DEBUG
            // Loud failure during development so the bug is impossible
            // to miss. Crash here means setup_new_user / use_invite
            // didn't write company_id, OR profile fetch hit a stale row.
            assertionFailure("Profile loaded without company_id — refusing to sign in. user=\(profile.id) email=\(profile.email)")
            #endif
            print("⛔ LOGIN GUARD: profile.companyID is nil — aborting sign-in for \(profile.email)")
            try? await AuthService.signOut()
            await MainActor.run {
                store.fullSignOutReset()
                self.errorMessage = "Account setup incomplete — your profile is missing a company. Contact support."
                self.isLoading    = false
            }
            return
        }

        // ── Debug telemetry (temporary) ──────────────────────────────
        // Remove after tenant-switching is confirmed stable across
        // the validation matrix. These logs prove which company_id
        // was attached at login and which one the SyncEngine pulled
        // against — they should always match.
        print("🔐 LOGIN → user=\(profile.id) email=\(profile.email) company_id=\(companyID) role=\(profile.role.rawValue)")

        var user = Employee(
            firstName: profile.fullName.components(separatedBy: " ").first ?? "",
            lastName:  profile.fullName.components(separatedBy: " ").dropFirst().joined(separator: " ")
        )
        user.id    = profile.id
        user.email = profile.email
        user.role  = profile.role

        await MainActor.run {
            // Defensive cache clear — even though sign-out is supposed to
            // call fullSignOutReset(), this guarantees no residual @Published
            // arrays survive into the new session. Without this, a stale
            // realtime push that landed between sign-out and sign-in could
            // briefly flash the previous tenant's data before pullAll
            // overwrites it. Cheap insurance.
            store.clearAllData()

            store.currentUser      = user
            store.currentUserRole  = profile.role
            store.currentCompanyID = companyID  // unwrapped non-optional

            // Phase 1 Step 3: attach the LocalPendingStore to the freshly
            // resolved tenant and replay any pending rows from a prior
            // session. Must run AFTER currentCompanyID is set; the call
            // is async-fire-and-forget (Task inside) so it does not block
            // the login UI handoff.
            store.bindLocalPersistence(companyID: companyID)
        }

        Task {
            // Sync guard — re-check the store's currentCompanyID at the
            // moment this Task fires, NOT the captured local. This protects
            // against:
            //   - a future reorder of the MainActor block above that lets
            //     this Task start before the assignment lands
            //   - an interleaved sign-out (auth listener firing mid-flight)
            //     that nilled the company before pullAll runs
            //   - regressions where someone removes the assignment by accident
            guard let activeCompanyID = await store.currentCompanyID else {
                print("⛔ SYNC BLOCKED — missing company_id (login Task)")
                return
            }
            print("🔄 SYNC → pulling for company_id=\(activeCompanyID)")
            // Load tenant-scoped settings BEFORE the data pull, so any
            // formatter or default value the pull depends on (currency,
            // tax rate) is correct at the moment of decode.
            await AppSettings.shared.loadForCompany(activeCompanyID)
            await SyncEngine.shared.pullAll(for: profile.id, role: profile.role)
        }

        await MainActor.run {
            store.isAuthenticated = true
        }
    }

    private func friendlyError(_ error: Error) -> String {
        let msg = error.localizedDescription.lowercased()
        if msg.contains("invalid login") || msg.contains("invalid credentials") || msg.contains("email") {
            return "Invalid email or password. Please try again."
        } else if msg.contains("network") || msg.contains("offline") || msg.contains("connection") {
            return "No internet connection. Check your network and try again."
        } else if msg.contains("too many") || msg.contains("rate") {
            return "Too many attempts. Please wait a moment and try again."
        } else {
            return "Sign in failed. Please try again."
        }
    }

    private func friendlySignUpError(_ error: Error) -> String {
        let msg = error.localizedDescription.lowercased()
        if msg.contains("already registered") || msg.contains("already exists") || msg.contains("unique") {
            return "An account with this email already exists. Try signing in instead."
        } else if msg.contains("password") || msg.contains("weak") {
            return "Password must be at least 6 characters."
        } else if msg.contains("network") || msg.contains("offline") {
            return "No internet connection. Check your network and try again."
        } else {
            return "Account creation failed. Please try again."
        }
    }
}

// Identifiable wrapper so .sheet(item:) can key off the factor ID
private struct MFAFactorItem: Identifiable { let id: String }

