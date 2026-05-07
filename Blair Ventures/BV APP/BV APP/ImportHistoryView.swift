// ImportHistoryView.swift
// Aski IQ – Import Batch History + Rollback

import SwiftUI

struct ImportHistoryView: View {
    @EnvironmentObject var store: AppStore
    @State private var showRollbackConfirm = false
    @State private var selectedBatch: ImportBatch?

    private var batches: [ImportBatch] {
        store.importBatches.sorted { ($0.createdAt) > ($1.createdAt) }
    }

    var body: some View {
        Group {
            if batches.isEmpty {
                ContentUnavailableView(
                    "No Imports Yet",
                    systemImage: "arrow.up.doc",
                    description: Text("Import history will appear here after your first import.")
                )
            } else {
                List {
                    ForEach(batches) { batch in
                        BatchRow(batch: batch) {
                            selectedBatch = batch
                            showRollbackConfirm = true
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Import History")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Roll Back Import?",
            isPresented: $showRollbackConfirm,
            titleVisibility: .visible
        ) {
            Button("Roll Back", role: .destructive) {
                if let b = selectedBatch { store.rollback(batchID: b.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let b = selectedBatch {
                Text("This will mark batch \(b.id.uuidString.prefix(8).uppercased()) as Rolled Back. " +
                     "Records created by this import must be removed manually in this version.")
            }
        }
    }
}

private struct BatchRow: View {
    let batch: ImportBatch
    let onRollback: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(batch.recordType, systemImage: "doc.fill")
                    .font(.subheadline).bold()

                Spacer()

                Label(batch.status.rawValue, systemImage: batch.status.icon)
                    .font(.caption)
                    .foregroundColor(batch.status.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(batch.status.color.opacity(0.12))
                    .cornerRadius(6)
            }

            Text(batch.fileName)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            HStack(spacing: 16) {
                StatBadge(value: batch.created,    label: "Created", color: .green)
                StatBadge(value: batch.updated,    label: "Updated", color: .blue)
                StatBadge(value: batch.skipped,    label: "Skipped", color: .secondary)
                StatBadge(value: batch.errorCount, label: "Errors",  color: .red)
            }

            HStack {
                Text("Batch: \(batch.id.uuidString.prefix(8).uppercased())")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Text(batch.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if batch.canRollback {
                Button(action: onRollback) {
                    Label("Roll Back", systemImage: "arrow.uturn.backward")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct StatBadge: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 1) {
            Text("\(value)")
                .font(.caption).bold()
                .foregroundColor(value > 0 ? color : .secondary)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}
