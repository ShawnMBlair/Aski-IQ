// SitePickerSheet.swift
// Aski IQ – Site Picker for Estimate Creation
// Filters sites by selected client. Requires client selection first.

import SwiftUI

// MARK: - Site Picker Sheet

struct SitePickerSheet: View {
    let clientID: UUID
    @Binding var selectedSiteID: UUID?
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var showAddSite = false

    private var client: Client? {
        store.client(id: clientID)
    }

    private var sites: [ClientSite] {
        (client?.sites ?? []).sorted { ($0.isDefault ? 0 : 1) < ($1.isDefault ? 0 : 1) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sites.isEmpty {
                    // Empty state — prompt to add first site
                    VStack(spacing: 20) {
                        Spacer()
                        Image(systemName: "mappin.slash.circle")
                            .font(.system(size: 52))
                            .foregroundColor(.secondary)
                        Text("No Sites for \(client?.name ?? "this client")")
                            .font(.headline)
                        Text("A site is required before creating an estimate.\nAdd the location where this work will be performed.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button {
                            showAddSite = true
                        } label: {
                            Label("Add First Site", systemImage: "plus.circle.fill")
                                .font(.headline)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(Color.orange)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                                .padding(.horizontal)
                        }
                        Spacer()
                    }
                } else {
                    List {
                        // Existing sites
                        Section {
                            ForEach(sites) { site in
                                Button {
                                    selectedSiteID = site.id
                                    dismiss()
                                } label: {
                                    SitePickerRow(site: site, isSelected: selectedSiteID == site.id)
                                }
                                .foregroundColor(.primary)
                            }
                        } header: {
                            Text(client?.name ?? "Sites")
                        }

                        // Add new site inline
                        Section {
                            Button {
                                showAddSite = true
                            } label: {
                                Label("Add New Site", systemImage: "plus.circle")
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Select Site")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showAddSite) {
                if let c = client {
                    AddSiteAndSelectSheet(client: c) { newSiteID in
                        selectedSiteID = newSiteID
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Site Picker Row

struct SitePickerRow: View {
    let site: ClientSite
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: isSelected ? "mappin.circle.fill" : "mappin.circle")
                .font(.title2)
                .foregroundColor(isSelected ? .orange : .secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(site.name).font(.subheadline).bold()
                    if site.isDefault {
                        Text("Default")
                            .font(.caption2).bold()
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.green.opacity(0.12))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                    }
                }
                let addr = site.formattedAddress.isEmpty ? site.address : site.formattedAddress
                if !addr.isEmpty {
                    Text(addr).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                if let access = site.accessNotes, !access.isEmpty {
                    Label(access, systemImage: "key.fill")
                        .font(.caption2)
                        .foregroundColor(.blue)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Add Site + Auto-Select Sheet
// Creates a new site and immediately selects it, then dismisses both sheets.

struct AddSiteAndSelectSheet: View {
    let client: Client
    let onCreated: (UUID) -> Void

    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    @State private var siteName       = ""
    @State private var address        = ""
    @State private var city           = ""
    @State private var province       = ""
    @State private var postalCode     = ""
    @State private var accessNotes    = ""
    @State private var safetyNotes    = ""
    @State private var logisticsNotes = ""

    @State private var isSaving       = false
    @State private var errorMessage:  String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("Site Details *") {
                    TextField("Site Name (e.g. Joffre Upgrader – Unit 2)", text: $siteName)
                    AddressSearchRow(
                        label:      "Site Address",
                        street:     $address,
                        city:       $city,
                        province:   $province,
                        postalCode: $postalCode
                    )
                    if !address.isEmpty {
                        TextField("Street", text: $address)
                    }
                    TextField("City", text: $city)
                    TextField("Province", text: $province)
                    TextField("Postal / ZIP", text: $postalCode)
                }
                Section("Access Notes") {
                    TextField("Gate code, parking, security check-in…", text: $accessNotes)
                }
                Section("Safety Notes") {
                    TextField("PPE requirements, H2S zones, site hazards…", text: $safetyNotes)
                }
                Section("Logistics Notes") {
                    TextField("Parking, staging area, laydown yard…", text: $logisticsNotes)
                }
                if let err = errorMessage {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("New Site — \(client.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Add & Select").bold()
                        }
                    }
                    .disabled(siteName.trimmingCharacters(in: .whitespaces).isEmpty
                              || address.isEmpty
                              || isSaving)
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isSaving)
    }

    /// Stabilization fix:
    ///   1. Re-fetch the live client from the store before mutating —
    ///      the captured `client` could be stale if other edits landed
    ///      between sheet open and save.
    ///   2. Wait for the push to complete BEFORE dismissing so the user
    ///      doesn't see "site saved" toasts then a vanished site.
    ///   3. Surface push errors instead of silently swallowing them.
    @MainActor
    private func save() async {
        let fullAddress = [address, city, province, postalCode]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")

        // Re-fetch live client. If the row vanished mid-flow (deleted
        // by another device), bail with a clear error.
        guard let liveClient = store.client(id: client.id) else {
            errorMessage = "This client was removed. Close this sheet and pick another client."
            return
        }

        let newSite = ClientSite(
            name:             siteName.trimmingCharacters(in: .whitespaces),
            address:          fullAddress,
            city:             city.isEmpty ? nil : city,
            province:         province.isEmpty ? nil : province,
            postalCode:       postalCode.isEmpty ? nil : postalCode,
            accessNotes:      accessNotes.isEmpty ? nil : accessNotes,
            safetyNotes:      safetyNotes.isEmpty ? nil : safetyNotes,
            logisticsNotes:   logisticsNotes.isEmpty ? nil : logisticsNotes,
            isDefault:        liveClient.sites.isEmpty  // First site = default
        )

        var updated = liveClient
        updated.sites.append(newSite)

        // DIAGNOSTIC: confirm what we're about to write. If `sites.count`
        // shows 0 here, the bug is on the iOS side (the append silently
        // didn't take). If it shows N then the push is the suspect.
        print("📍 AddSiteAndSelect.save: appending '\(newSite.name)' to '\(updated.name)'. Site count BEFORE upsert = \(updated.sites.count)")

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        store.upsertClient(updated)

        // Verify the local store actually took our update. If the
        // count dropped between upsertClient and now, something
        // mutated the row out from under us.
        let postUpsertLocal = store.client(id: client.id)
        print("📍 AddSiteAndSelect.save: post-upsertClient local site count = \(postUpsertLocal?.sites.count ?? -1) (should be \(updated.sites.count))")

        // Wait for the push to confirm. upsertClient launches a Task
        // internally; we explicitly drain the pending queue here so
        // the user sees the site land before the sheet closes.
        await SyncEngine.shared.pushPendingClients()

        // Verify post-push status. If the row went to .failed the user
        // needs to retry — don't dismiss with stale state.
        let postPush = store.client(id: client.id)
        print("📍 AddSiteAndSelect.save: post-push site count = \(postPush?.sites.count ?? -1), syncStatus = \(String(describing: postPush?.syncStatus))")

        if postPush?.syncStatus == .failed {
            errorMessage = "Couldn't save the site to the server. Check your connection and try again. Open the Xcode console for the underlying error."
            Haptics.error()
            return
        }

        // Confirm to the user that the site landed. Pre-fix the sheet
        // dismissed silently on success, which made it impossible to
        // tell whether sites were actually persisting.
        ToastService.shared.success(
            "Site saved",
            body: "\(newSite.name) is now saved to \(liveClient.name)."
        )
        Haptics.success()
        onCreated(newSite.id)
        dismiss()
    }
}
