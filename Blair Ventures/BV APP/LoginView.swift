// LoginView.swift
// Blair Ventures – Authentication Gate

import SwiftUI

struct LoginView: View {
    @Binding var isAuthenticated: Bool
    @EnvironmentObject var store: AppStore

    @State private var email        = ""
    @State private var password     = ""
    @State private var isLoading    = false
    @State private var errorMessage: String? = nil
    @State private var showDemoSheet = false
    @FocusState private var focusedField: Field?

    private enum Field { case email, password }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {

                // MARK: - Branding Header
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.15))
                            .frame(width: 96, height: 96)
                        Image(systemName: "building.2.fill")
                            .font(.system(size: 44))
                            .foregroundColor(.orange)
                    }

                    Text("Blair Ventures")
                        .font(.largeTitle).bold()

                    Text("Construction Management")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 72)
                .padding(.bottom, 48)

                // MARK: - Login Card
                VStack(spacing: 20) {

                    // Email field
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Email", systemImage: "envelope.fill")
                            .font(.caption).bold()
                            .foregroundColor(.secondary)
                        TextField("you@blairventures.ca", text: $email)
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
                            .font(.caption).bold()
                            .foregroundColor(.secondary)
                        SecureField("Enter your password", text: $password)
                            .textContentType(.password)
                            .focused($focusedField, equals: .password)
                            .padding(12)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(10)
                    }

                    // Error message
                    if let error = errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .padding(10)
                        .background(Color.red.opacity(0.08))
                        .cornerRadius(8)
                    }

                    // Sign In button
                    Button {
                        focusedField = nil
                        Task { await signIn() }
                    } label: {
                        ZStack {
                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("Sign In")
                                    .font(.headline)
                                    .foregroundColor(.white)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(canSignIn ? Color.orange : Color.gray.opacity(0.5))
                        .cornerRadius(12)
                    }
                    .disabled(!canSignIn || isLoading)

                    Divider()

                    // Demo mode bypass
                    Button {
                        showDemoSheet = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.caption)
                            Text("Demo Mode — Browse with Sample Data")
                                .font(.subheadline)
                        }
                        .foregroundColor(.blue)
                    }
                }
                .padding(24)
                .background(Color(.systemBackground))
                .cornerRadius(16)
                .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 4)
                .padding(.horizontal, 24)

                Spacer(minLength: 48)

                Text("© \(currentYear) Blair Ventures Ltd.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 24)
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .sheet(isPresented: $showDemoSheet) {
            DemoRoleSelectorView(isAuthenticated: $isAuthenticated)
                .environmentObject(store)
        }
        .onSubmit {
            if focusedField == .email {
                focusedField = .password
            } else if canSignIn {
                Task { await signIn() }
            }
        }
    }

    // MARK: - Helpers

    private var canSignIn: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty
    }

    private var currentYear: String {
        String(Calendar.current.component(.year, from: Date()))
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

            // Build employee record from profile
            var user = Employee(
                firstName: profile.fullName.components(separatedBy: " ").first ?? "",
                lastName:  profile.fullName.components(separatedBy: " ").dropFirst().joined(separator: " ")
            )
            user.id    = profile.id
            user.email = profile.email
            user.role  = profile.role

            await MainActor.run {
                store.currentUser     = user
                store.currentUserRole = profile.role
            }

            // Kick off background sync
            Task {
                await SyncEngine.shared.pullAll(for: profile.id, role: profile.role)
            }

            await MainActor.run {
                isAuthenticated = true
            }

        } catch {
            await MainActor.run {
                isLoading    = false
                errorMessage = friendlyError(error)
            }
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
}

// MARK: - Demo Role Selector

struct DemoRoleSelectorView: View {
    @Binding var isAuthenticated: Bool
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    private let demoAccounts: [(role: UserRole, name: String, email: String)] = [
        (.executive,      "Alex Blair",       "alex@blairventures.ca"),
        (.manager,        "Jordan Blair",     "jordan@blairventures.ca"),
        (.projectManager, "Sam Torres",       "sam.torres@blairventures.ca"),
        (.estimator,      "Casey Nguyen",     "casey.nguyen@blairventures.ca"),
        (.officeAdmin,    "Dana McAllister",  "dana@blairventures.ca"),
        (.foreman,        "Mike Rivera",      "mike.rivera@blairventures.ca"),
        (.fieldWorker,    "Tyler Johnson",    "tyler.j@blairventures.ca"),
        (.client,         "Client Portal",    "client@example.com"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Select a role to explore Blair Ventures with sample data. No Supabase connection required.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .listRowBackground(Color.clear)
                }

                Section("Select Demo Role") {
                    ForEach(demoAccounts, id: \.role) { account in
                        Button {
                            enterDemo(account)
                        } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle()
                                        .fill(roleColor(account.role).opacity(0.15))
                                        .frame(width: 44, height: 44)
                                    Image(systemName: account.role.icon)
                                        .foregroundColor(roleColor(account.role))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.name)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text(account.role.displayName)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Demo Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func enterDemo(_ account: (role: UserRole, name: String, email: String)) {
        let nameParts = account.name.components(separatedBy: " ")
        var user = Employee(
            firstName: nameParts.first ?? "",
            lastName:  nameParts.dropFirst().joined(separator: " ")
        )
        user.email    = account.email
        user.role     = account.role
        user.isActive = true

        store.currentUser     = user
        store.currentUserRole = account.role

        // Load sample data if store is empty
        if store.projects.isEmpty {
            store.loadSampleData()
        }

        dismiss()
        // Small delay so sheet dismisses cleanly before root view swaps
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            isAuthenticated = true
        }
    }

    private func roleColor(_ role: UserRole) -> Color {
        switch role {
        case .fieldWorker:    return .green
        case .foreman:        return .orange
        case .projectManager: return .blue
        case .estimator:      return .purple
        case .officeAdmin:    return .teal
        case .manager:        return .indigo
        case .executive:      return .red
        case .client:         return .gray
        }
    }
}
