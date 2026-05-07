// CompanyAIPromptEditorView.swift
// Aski IQ — Admin UI for per-company AI prompt overrides (deferred Phase 2).
//
// Lives behind a Settings → AI Features → "Customize AI Prompts" entry
// (admin-only). Lists all four customizable surfaces with their current
// override status; tapping a row opens a per-surface editor that lets
// the admin paste a replacement system prompt or clear it back to the
// iOS default.
//
// SAFETY
// Replacement prompts are FULL replacements — there's no merging. We
// surface a 1500-char soft warning because Claude's prompt budget
// counts toward max_tokens and a 5000-char system prompt could cap
// out short responses.

import SwiftUI

struct CompanyAIPromptEditorView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var service = CompanyAIPromptService.shared

    @State private var editing: CompanyAIPromptService.Surface?
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Override the system prompt that drives each AI surface. Empty = use the Aski IQ default. Changes apply on the next AI call across all devices in your company.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if service.isFetching {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("Loading…").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }

                if let err = loadError {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red).font(.caption)
                    }
                }

                Section("Surfaces") {
                    ForEach(CompanyAIPromptService.Surface.allCases) { surface in
                        Button {
                            editing = surface
                        } label: {
                            row(for: surface)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    Text("Need a starting point? Paste your default into the editor first, edit it, then save. The Aski IQ default keeps running until you do.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Customize AI Prompts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                _ = await service.fetchAll()
            }
            .sheet(item: $editing) { surface in
                PromptEditorSheet(surface: surface)
                    .environmentObject(store)
            }
        }
    }

    @ViewBuilder
    private func row(for surface: CompanyAIPromptService.Surface) -> some View {
        let hasOverride = service.cached[surface] != nil
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(surface.displayName).font(.subheadline.weight(.semibold))
                Spacer()
                if hasOverride {
                    Text("Custom")
                        .font(.caption2).bold()
                        .foregroundColor(.purple)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.purple.opacity(0.15))
                        .clipShape(Capsule())
                } else {
                    Text("Default")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundColor(.secondary)
            }
            Text(surface.helperText)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Per-surface editor

private struct PromptEditorSheet: View {
    let surface: CompanyAIPromptService.Surface
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var service = CompanyAIPromptService.shared

    @State private var draft:    String = ""
    @State private var isSaving: Bool   = false
    @State private var error:    String?

    private var charCount: Int { draft.count }
    private var isLong:    Bool { charCount > 1500 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(surface.helperText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .listRowBackground(Color.clear)
                }

                Section {
                    TextEditor(text: $draft)
                        .font(.system(.subheadline, design: .monospaced))
                        .frame(minHeight: 220)
                } header: {
                    Text("System prompt")
                } footer: {
                    HStack {
                        Text("\(charCount) chars")
                        Spacer()
                        if isLong {
                            Label("Long prompts eat into the response budget",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption2)
                        }
                    }
                }

                if let err = error {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red).font(.caption)
                    }
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack {
                            if isSaving { ProgressView().scaleEffect(0.85) }
                            Text(isSaving ? "Saving…" : "Save Override")
                        }
                        .frame(maxWidth: .infinity)
                        .foregroundColor(.white)
                    }
                    .listRowBackground(Color.purple)
                    .disabled(isSaving || draft.isEmpty)

                    if service.cached[surface] != nil {
                        Button(role: .destructive) {
                            Task { await clear() }
                        } label: {
                            Label("Clear override (use default)",
                                  systemImage: "arrow.counterclockwise")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .navigationTitle(surface.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                draft = service.cached[surface] ?? ""
            }
        }
    }

    private func save() async {
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            try await service.set(surface: surface, prompt: draft)
            ToastService.shared.success("AI prompt updated.")
            dismiss()
        } catch let err as CompanyAIPromptService.PromptError {
            error = err.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func clear() async {
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            try await service.set(surface: surface, prompt: "")
            ToastService.shared.warning("Reverted to default — AI calls now use Aski IQ's built-in prompt.")
            dismiss()
        } catch let err as CompanyAIPromptService.PromptError {
            error = err.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}
