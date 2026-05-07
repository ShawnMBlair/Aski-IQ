// AIDocumentService.swift
// BV APP – AI document summarization via Claude

import Foundation
import SwiftUI
import Combine

// MARK: - AI Document Service

final class AIDocumentService: ObservableObject {

    static let shared = AIDocumentService()

    @Published var isLoading = false
    @Published var summary: String? = nil
    @Published var error: String? = nil

    init() {}

    /// Sends text to Claude (via the `ai-proxy` Edge Function) and returns
    /// a structured summary. The proxy holds the Anthropic API key server-
    /// side, so no per-user key configuration is needed.
    @MainActor
    func summarize(text: String, context: String = "construction field operations document") async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "No text content to summarize."
            return
        }

        isLoading = true
        summary = nil
        error = nil

        let prompt = """
        You are an assistant for a construction and field operations management platform called Aski IQ.
        Summarize the following \(context) in a concise, structured format.
        Include: key facts, dates, parties involved, action items or obligations, and any notable risks or flags.
        Keep the summary under 200 words.

        Document:
        \(text.prefix(8000))
        """

        let payload: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 512,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        switch await AIProxyClient.shared.sendText(payload: payload) {
        case .success(let text):
            summary = text
        case .failure(let err):
            error = err.userMessage
        }
        isLoading = false
    }
}

// MARK: - AI Summary Sheet

struct AISummarySheet: View {
    let documentText: String
    let contextLabel: String
    @StateObject private var service = AIDocumentService()
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if service.isLoading {
                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.4)
                                .padding(.top, 40)
                            Text("Analyzing document…")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    } else if let summary = service.summary {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("AI Summary", systemImage: "sparkles")
                                .font(.headline)
                                .foregroundColor(.purple)

                            Text(summary)
                                .font(.subheadline)
                                .padding()
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(12)
                        }
                        .padding(.horizontal)
                    } else if let err = service.error {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.largeTitle)
                                .foregroundColor(.orange)
                                .padding(.top, 40)
                            Text(err)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    }

                    Spacer(minLength: 40)
                }
                .padding(.top)
            }
            .navigationTitle("AI Document Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await service.summarize(text: documentText, context: contextLabel)
            }
        }
    }
}

// MARK: - Inline Summarize Button

struct AISummarizeButton: View {
    let text: String
    let context: String

    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.purple.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.purple)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Summarize with AI")
                        .font(.subheadline).bold()
                        .foregroundColor(.primary)
                    Text("Claude · Key facts, actions & risks")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSheet) {
            AISummarySheet(documentText: text, contextLabel: context)
        }
    }
}
