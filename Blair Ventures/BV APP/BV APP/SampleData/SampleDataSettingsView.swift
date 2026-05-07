// SampleDataSettingsView.swift
// Aski IQ — Admin Settings panel for Load + Clear Sample Data.
//
// Visible only to executive + officeAdmin. Load is allowed for both;
// Clear is restricted to executive (matches the RPC's role check).
// Confirmation is by typed phrase per architecture decision: caller
// must type "DELETE SAMPLE DATA" exactly.

import SwiftUI

struct SampleDataSettingsView: View {
    @EnvironmentObject var store: AppStore

    @State private var isLoading       = false
    @State private var isClearing      = false
    @State private var loadResult:   SampleDataLoadResult?
    @State private var clearResult:  SampleDataResetService.ResetResult?
    @State private var errorMessage: String?

    @State private var showClearConfirm = false
    @State private var typedConfirmation = ""

    private var canLoad:  Bool { [.executive, .officeAdmin].contains(store.currentUserRole) }
    private var canClear: Bool { store.currentUserRole == .executive }

    private var activeBatchID: UUID? {
        guard let cid = store.currentCompanyID else { return nil }
        return SampleDataActiveBatch.get(companyID: cid)
    }

    var body: some View {
        Section {
            statusRow
            if let err = errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            if isLoading || isClearing {
                ProgressView(isLoading ? "Loading sample data…" : "Clearing sample data…")
                    .progressViewStyle(.linear)
            } else {
                if activeBatchID == nil, canLoad {
                    Button {
                        Task { await load() }
                    } label: {
                        Label("Load Sample Data", systemImage: "square.and.arrow.down.fill")
                    }
                } else if activeBatchID != nil, canClear {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("Clear Sample Data", systemImage: "trash")
                    }
                } else if activeBatchID != nil, !canClear {
                    Text("Only an executive can clear sample data. Ask an exec to remove it.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            if let res = loadResult {
                loadSummary(res)
            }
            if let res = clearResult {
                clearSummary(res)
            }
        } header: {
            Text("Sample Data")
        } footer: {
            Text("Sample data is loaded into your real tenant with the `is_sample_data` flag set on every record. Clearing removes only those flagged records — your real data is never touched. Reversible. Tenant-scoped.")
        }
        .alert("Clear Sample Data?", isPresented: $showClearConfirm) {
            TextField("Type DELETE SAMPLE DATA", text: $typedConfirmation)
                .textInputAutocapitalization(.characters)
                .disableAutocorrection(true)
            Button("Cancel", role: .cancel) {
                typedConfirmation = ""
            }
            Button("Delete", role: .destructive) {
                Task { await clear() }
            }
            .disabled(typedConfirmation != "DELETE SAMPLE DATA")
        } message: {
            Text("This will permanently remove all sample data for this company. Real data will not be deleted. Type DELETE SAMPLE DATA to continue.")
        }
    }

    // MARK: - Status row

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(activeBatchID != nil
                          ? Color.green.opacity(0.15)
                          : Color.secondary.opacity(0.10))
                    .frame(width: 36, height: 36)
                Image(systemName: activeBatchID != nil
                      ? "checkmark.circle.fill"
                      : "circle.dashed")
                    .foregroundColor(activeBatchID != nil ? .green : .secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(activeBatchID != nil ? "Sample data loaded" : "No sample data")
                    .font(.subheadline).fontWeight(.semibold)
                if let id = activeBatchID {
                    Text("Batch \(id.uuidString.prefix(8))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fontDesign(.monospaced)
                } else {
                    Text("Load to populate every module with realistic records.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Result summaries

    private func loadSummary(_ res: SampleDataLoadResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Loaded \(res.totalRecords) records in \(String(format: "%.1f", res.durationSeconds))s")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.green)
            ForEach(res.perModuleCounts.sorted { $0.value > $1.value }, id: \.key) { entry in
                HStack {
                    Text(entry.key).font(.caption)
                    Spacer()
                    Text("\(entry.value)").font(.caption.monospacedDigit())
                }
                .foregroundColor(.secondary)
            }
        }
    }

    private func clearSummary(_ res: SampleDataResetService.ResetResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Cleared \(res.totalDeleted) records")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.orange)
            ForEach(res.perTableCounts.sorted { $0.value > $1.value }, id: \.key) { entry in
                if entry.value > 0 {
                    HStack {
                        Text(entry.key).font(.caption)
                        Spacer()
                        Text("\(entry.value)").font(.caption.monospacedDigit())
                    }
                    .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        errorMessage = nil
        loadResult   = nil
        clearResult  = nil
        isLoading    = true
        defer { isLoading = false }

        do {
            let dataset = try SampleDataParser.loadEmbedded()
            let seeder  = try SampleDataSeeder(
                store:             store,
                dataset:           dataset,
                currentAppVersion: Bundle.main.appVersion
            )
            loadResult = try await seeder.load()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func clear() async {
        guard let cid = store.currentCompanyID,
              let bid = activeBatchID else { return }
        errorMessage = nil
        clearResult  = nil
        loadResult   = nil
        isClearing   = true
        typedConfirmation = ""
        defer { isClearing = false }

        do {
            clearResult = try await SampleDataResetService.shared.clear(
                companyID:     cid,
                batchID:       bid,
                store:         store,
                source:        .userClear
            )
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Bundle version helper

private extension Bundle {
    var appVersion: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }
}
