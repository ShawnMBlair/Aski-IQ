// AIChatView.swift
// BV APP – Conversational AI assistant with live app data context

import SwiftUI
import Combine

// MARK: - Chat Message Model

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: Role
    var content: String
    let timestamp: Date = Date()

    enum Role { case user, assistant }
}

// MARK: - Chat Service

@MainActor
final class AIChatService: ObservableObject {
    static let shared = AIChatService()

    @Published var messages: [ChatMessage] = []
    @Published var isLoading = false
    @Published var error: String? = nil

    private init() {}

    /// True when a streaming response is actively producing tokens.
    /// The chat view binds this to render an "is typing" pulse on the
    /// in-progress assistant bubble (different visual from the pre-
    /// first-token loading dots).
    @Published var isStreaming = false

    func send(userText: String, context: String) async {
        guard !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        messages.append(ChatMessage(role: .user, content: userText))
        isLoading = true
        error = nil

        // Build message history for multi-turn — same shape Anthropic
        // expects on the upstream side; the ai-proxy Edge Function
        // forwards the body verbatim.
        let history: [[String: String]] = messages.dropLast().map {
            ["role": $0.role == .user ? "user" : "assistant", "content": $0.content]
        } + [["role": "user", "content": userText]]

        let truncatedContext = String(context.prefix(4000))
        // Phase-2 deferred: per-company prompt customization. The
        // `effectivePrompt(for:fallback:)` call returns the admin's
        // override when one is set (companies.ai_prompt_overrides),
        // otherwise our hard-coded baseline. Tenants without an
        // override see no behavior change.
        let resolvedSystem = CompanyAIPromptService.shared.effectivePrompt(
            for:      .chat,
            fallback: systemPrompt(context: truncatedContext)
        )
        let payload: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 512,
            "stream": true,
            "system": resolvedSystem,
            "messages": history
        ]

        // Insert an empty assistant message that we'll mutate as deltas
        // arrive. Doing this BEFORE the first token lets the UI paint
        // the bubble immediately so it's clear something is happening.
        let placeholderID = UUID()
        messages.append(ChatMessage(role: .assistant, content: ""))
        let assistantIndex = messages.count - 1

        do {
            let stream = AIProxyClient.shared.streamText(payload: payload)
            for try await delta in stream {
                if !isStreaming { isStreaming = true; isLoading = false }
                // Mutate in place. Index could shift if user clears
                // history mid-stream — guard against that.
                if assistantIndex < messages.count,
                   messages[assistantIndex].role == .assistant {
                    messages[assistantIndex].content += delta
                }
            }
            // If the stream produced nothing (rare — usually a 4xx
            // returned as JSON before the SSE flow even started)
            // remove the empty bubble so the UI doesn't show a
            // ghost reply.
            if assistantIndex < messages.count,
               messages[assistantIndex].content.isEmpty {
                messages.remove(at: assistantIndex)
                error = "AI returned no content. Try again."
            }
        } catch let err as AIProxyClient.AIProxyError {
            error = err.userMessage
            // Roll back the empty assistant placeholder so we don't
            // leave a blank bubble on failure.
            if assistantIndex < messages.count,
               messages[assistantIndex].role == .assistant,
               messages[assistantIndex].content.isEmpty {
                messages.remove(at: assistantIndex)
            }
        } catch {
            self.error = error.localizedDescription
            if assistantIndex < messages.count,
               messages[assistantIndex].role == .assistant,
               messages[assistantIndex].content.isEmpty {
                messages.remove(at: assistantIndex)
            }
        }

        isStreaming = false
        isLoading = false

        // Suppress the placeholder warning — the optimistic ID isn't
        // used downstream, but Swift's unused-let lint will complain
        // without something referencing it.
        _ = placeholderID
    }

    func clearHistory() {
        messages = []
        error = nil
    }

    private func systemPrompt(context: String) -> String {
        """
        You are Aski, an AI operations assistant built into Aski IQ — a construction management platform.
        You have access to the following live data snapshot from the app, which includes projects, crew, timesheets, safety incidents, estimates, invoices, CRM contacts, opportunities, tasks, and financials:

        \(context)

        Guidelines:
        - Be concise and direct. Bullet points for lists.
        - When referencing numbers or names, use the data above.
        - If something isn't in the data snapshot, say so honestly.
        - You can give recommendations based on the data (e.g. flag overdue items, crew conflicts, safety concerns, sales pipeline health).
        - Keep responses under 150 words unless the user asks for detail.
        - Address the user by first name if known from the context.
        """
    }
}

// MARK: - Chat View

struct AIChatView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var service = AIChatService.shared
    @Environment(\.dismiss) var dismiss

    @State private var inputText = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // No more API-key gate: the ai-proxy Edge Function holds
                // the Anthropic key server-side and authenticates the
                // caller via their Supabase JWT. If the server-side secret
                // isn't set yet, the first call returns 503 and the user
                // sees "AI features aren't activated — contact your admin"
                // in the standard error banner below.
                ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                if service.messages.isEmpty {
                                    proactiveGreeting
                                        .padding(.top, 24)
                                }
                                ForEach(service.messages) { msg in
                                    MessageBubble(message: msg)
                                        .id(msg.id)
                                }
                                if service.isLoading {
                                    TypingIndicator()
                                        .id("typing")
                                }
                                Color.clear.frame(height: 8).id("bottom")
                            }
                            .padding(.horizontal)
                            .padding(.top, 8)
                        }
                        .onChange(of: service.messages.count) {
                            withAnimation { proxy.scrollTo("bottom") }
                        }
                        .onChange(of: service.isLoading) {
                            withAnimation { proxy.scrollTo("bottom") }
                        }
                    }

                    if let err = service.error {
                        errorBanner(err)
                            .padding(.horizontal, 14)
                            .padding(.top, 6)
                    }

                Divider()

                // Input bar
                inputBar
            }
            .navigationTitle("Aski AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        service.clearHistory()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .disabled(service.messages.isEmpty)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.primary)
            Spacer()
            Button {
                service.error = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
    }

    // MARK: Proactive greeting

    private var proactiveGreeting: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.purple.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: "sparkles")
                    .font(.system(size: 28))
                    .foregroundColor(.purple)
            }
            VStack(spacing: 6) {
                Text("Hey \(store.currentUser?.firstName ?? "there") 👋")
                    .font(.title3).bold()
                Text(greetingMessage)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            // Suggested prompts
            VStack(spacing: 8) {
                ForEach(suggestedPrompts, id: \.self) { prompt in
                    Button {
                        inputText = prompt
                        Task { await sendMessage() }
                    } label: {
                        Text(prompt)
                            .font(.subheadline)
                            .foregroundColor(.purple)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.purple.opacity(0.08))
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 8)
    }

    private var greetingMessage: String {
        let pending = store.pendingTimesheets().count
        let incidents = store.openIncidents.count
        let activeProjects = store.projects.filter { $0.status == .active }.count

        if incidents > 0 {
            return "You have \(incidents) open incident\(incidents == 1 ? "" : "s") and \(activeProjects) active project\(activeProjects == 1 ? "" : "s"). What do you need?"
        } else if pending > 0 {
            return "\(pending) timesheet\(pending == 1 ? "" : "s") pending approval across \(activeProjects) active projects. Ask me anything."
        } else {
            return "\(activeProjects) active project\(activeProjects == 1 ? "" : "s") running. Everything looks clear. Ask me anything."
        }
    }

    private var suggestedPrompts: [String] {
        var prompts: [String] = []
        if store.pendingTimesheets().count > 0 {
            prompts.append("Which timesheets need approval?")
        }
        if store.openIncidents.count > 0 {
            prompts.append("Summarize open incidents")
        }
        if store.overdueInvoices.count > 0 {
            prompts.append("What invoices are overdue?")
        }
        prompts.append("Which crews are on site today?")
        prompts.append("Give me a project status overview")
        return Array(prompts.prefix(4))
    }

    // MARK: Input bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask Aski anything…", text: $inputText, axis: .vertical)
                .lineLimit(1...4)
                .focused($inputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(20)
                .onSubmit { Task { await sendMessage() } }

            Button {
                Task { await sendMessage() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(canSend ? .purple : Color(.tertiaryLabel))
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !service.isLoading
    }

    private func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        await service.send(userText: text, context: store.chatContext)
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .assistant {
                ZStack {
                    Circle().fill(Color.purple.opacity(0.12)).frame(width: 28, height: 28)
                    Image(systemName: "sparkles").font(.system(size: 12)).foregroundColor(.purple)
                }
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 3) {
                Text(message.content)
                    .font(.subheadline)
                    .foregroundColor(message.role == .user ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(message.role == .user ? Color.purple : Color(.secondarySystemBackground))
                    .cornerRadius(18)
                    .cornerRadius(message.role == .user ? 4 : 18,
                                  corners: message.role == .user ? .bottomRight : .bottomLeft)

                Text(message.timestamp, style: .time)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            }
            .frame(maxWidth: UIScreen.main.bounds.width * 0.72,
                   alignment: message.role == .user ? .trailing : .leading)

            if message.role == .user { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }
}

// MARK: - Typing indicator

private struct TypingIndicator: View {
    @State private var phase = 0

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack {
                Circle().fill(Color.purple.opacity(0.12)).frame(width: 28, height: 28)
                Image(systemName: "sparkles").font(.system(size: 12)).foregroundColor(.purple)
            }
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 7, height: 7)
                        .scaleEffect(phase == i ? 1.3 : 0.8)
                        .animation(.easeInOut(duration: 0.4).repeatForever().delay(Double(i) * 0.15),
                                   value: phase)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(18)
            .cornerRadius(4, corners: .bottomLeft)
            Spacer()
        }
        .onAppear { phase = 1 }
    }
}

// MARK: - Rounded corner helper

private extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

private struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: UIRectCorner
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners,
                                cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

// MARK: - AppStore chat context

extension AppStore {
    var chatContext: String {
        let cal = Calendar.current
        let todayEntries = scheduleEntries.filter { cal.isDateInToday($0.date) }
        let todayCrewIDs = Set(todayEntries.compactMap(\.crewID))
        let todayCrews = crews.filter { todayCrewIDs.contains($0.id) }
        let activeProjects = projects.filter { $0.status == .active }
        let pending = pendingTimesheets()
        let overdue = overdueInvoices

        var lines: [String] = [
            "User: \(currentUser?.fullName ?? "Unknown") — Role: \(currentUserRole.displayName)",
            "Date: \(Date().formatted(date: .long, time: .omitted))",
            "",
            "=== PROJECTS ===",
            "Active: \(activeProjects.count) — \(activeProjects.map(\.name).joined(separator: ", "))",
            "On hold: \(projects.filter { $0.status == .onHold }.count)",
            "",
            "=== CREW & SCHEDULE ===",
            "Crews on site today (\(todayCrews.count)): \(todayCrews.map { "\($0.name) (\($0.memberIDs.count) members)" }.joined(separator: ", "))",
            "Total employees: \(employees.filter { $0.isActive }.count) active",
            "",
            "=== TIMESHEETS ===",
            "Pending approval: \(pending.count)",
            "",
            "=== SAFETY & INCIDENTS ===",
            "Open incidents: \(openIncidents.count)",
            openIncidents.prefix(3).map { "  • \($0.title) [\($0.severity.displayName)]" }.joined(separator: "\n"),
            "",
            "=== FINANCIAL ===",
            "Overdue invoices: \(overdue.count) totalling \(overdue.reduce(0) { $0 + $1.total }.currencyString)",
            "Active estimates: \(estimates.filter { $0.status.isActive }.count)",
            "Open RFIs: \(openRFIs.count)",
            "Open change orders: \(openChangeOrders.count)",
        ]

        // CRM
        let openOpps = crmOpportunities.filter { $0.stage != .won && $0.stage != .lost }
        let wonOpps  = crmOpportunities.filter { $0.stage == .won }
        let overdueCRMTasks = crmTasks.filter { $0.status != .done && ($0.dueDate ?? .distantFuture) < Date() }
        lines += [
            "",
            "=== CRM / SALES ===",
            "Active opportunities: \(openOpps.count) — pipeline value: \(openOpps.map(\.value).reduce(0, +).currencyString)",
            "Won deals: \(wonOpps.count)",
            "CRM contacts: \(crmContacts.count)",
            "Overdue CRM tasks: \(overdueCRMTasks.count)",
        ]
        if !openOpps.isEmpty {
            lines.append("Top opportunities: " + openOpps.prefix(3).map { "\($0.title) [\($0.stage.rawValue)]" }.joined(separator: ", "))
        }

        if let weather = currentWeather {
            lines += ["", "=== WEATHER ===", "\(weather.tempString), \(weather.conditionText). Wind: \(weather.windString)"]
        }

        return lines.joined(separator: "\n")
    }
}
