// AIChatView.swift
// BV APP – Conversational AI assistant with live app data context

import SwiftUI
import Combine

// MARK: - Chat Message Model

struct ChatMessage: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    let role: Role
    var content: String
    var timestamp: Date = Date()

    enum Role: String, Codable { case user, assistant }
}

// MARK: - Chat Thread Model
//
// Phase 8 / AI v2 — multiple parallel conversations. Each thread holds
// its own message list + metadata; AIChatService picks one as active
// at any time. UI sidebar (`ThreadListSheet`) lets the user switch
// between them. Same on-disk JSON blob holds all threads.

struct ChatThread: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var title: String                // auto-derived from first user message
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var messages: [ChatMessage] = []
    var isArchived: Bool = false

    /// Default title used when a thread is freshly created. The first
    /// user message replaces this via `autoTitleIfNeeded()`.
    static let defaultTitle = "New Chat"

    /// Preview text shown in the thread list — last assistant or user
    /// message, truncated. Empty threads show "(empty)".
    var preview: String {
        guard let last = messages.last else { return "(empty)" }
        return String(last.content.prefix(80))
    }
}

// MARK: - Chat Service

@MainActor
final class AIChatService: ObservableObject {
    static let shared = AIChatService()

    /// All threads, newest-first. The active thread is the one whose
    /// `id` matches `activeThreadID`; its messages are mirrored to
    /// `messages` for direct view-layer binding.
    @Published var threads: [ChatThread] = []
    @Published var activeThreadID: UUID? = nil

    /// Mirror of the active thread's messages. The send/stream path
    /// mutates this array; `persistActiveThread()` writes it back to
    /// `threads` and saves at safe points (after streaming completes,
    /// on thread switch, on clear). Doing the writeback on every token
    /// append would re-encode the entire threads blob hundreds of
    /// times per response — wasteful and noisy.
    @Published var messages: [ChatMessage] = []

    @Published var isLoading = false
    @Published var error: String? = nil

    /// True when a streaming response is actively producing tokens.
    /// The chat view binds this to render an "is typing" pulse on the
    /// in-progress assistant bubble (different visual from the pre-
    /// first-token loading dots).
    @Published var isStreaming = false

    // MARK: Persistence keys

    /// v2 threads blob — supersedes the v1 single-conversation key.
    private static let threadsKey       = "aski_ai_chat_threads_v1"
    private static let activeThreadKey  = "aski_ai_chat_active_thread_v1"
    /// v1 legacy key — migrated into a single thread on first launch
    /// of a build that has v2 threads. Cleared after migration so we
    /// don't double-import on subsequent launches.
    private static let legacyMessagesKey = "aski_ai_chat_history_v1"

    /// Per-thread message cap. Same as v1 — long-running conversations
    /// trim the oldest messages off the persisted copy. In-memory
    /// history is unbounded during a session.
    private static let persistedHistoryCap = 200

    /// Max threads we persist. Older / archived threads beyond this
    /// limit are dropped during save. The user can manually delete
    /// threads before then if storage feels stale.
    private static let persistedThreadCap = 50

    private init() {
        loadThreadsFromDisk()
    }

    // MARK: Load / save

    private func loadThreadsFromDisk() {
        let defaults = UserDefaults.standard

        // v2 path — threads blob exists.
        if let data = defaults.data(forKey: Self.threadsKey),
           let decoded = try? JSONDecoder().decode([ChatThread].self, from: data) {
            threads = decoded
            // Restore active selection. If the stored ID no longer
            // resolves (deleted thread, corrupt data), fall back to
            // the most recently updated one.
            if let activeStr = defaults.string(forKey: Self.activeThreadKey),
               let activeUUID = UUID(uuidString: activeStr),
               threads.contains(where: { $0.id == activeUUID }) {
                activeThreadID = activeUUID
            } else {
                activeThreadID = threads.first?.id
            }
            messages = threads.first(where: { $0.id == activeThreadID })?.messages ?? []
            return
        }

        // v1 → v2 one-time migration: if the legacy single-conversation
        // blob exists, fold it into one "Imported chat" thread and
        // wipe the legacy key. Devices updating from a pre-threads
        // build get their history preserved.
        if let data = defaults.data(forKey: Self.legacyMessagesKey),
           let legacyMessages = try? JSONDecoder().decode([ChatMessage].self, from: data),
           !legacyMessages.isEmpty {
            let migrated = ChatThread(
                title:    autoTitle(from: legacyMessages) ?? "Imported chat",
                messages: legacyMessages
            )
            threads = [migrated]
            activeThreadID = migrated.id
            messages = legacyMessages
            persistThreads()
            defaults.removeObject(forKey: Self.legacyMessagesKey)
            return
        }

        // No history at all — start empty. The first send() creates
        // the first thread on demand.
        threads = []
        activeThreadID = nil
        messages = []
    }

    /// Writes the active thread's current `messages` back into the
    /// `threads` array, then persists the full blob (trimmed). Called
    /// at safe points; NOT on every token to avoid re-encoding the
    /// whole list during streaming.
    private func persistActiveThread() {
        guard let aid = activeThreadID,
              let idx = threads.firstIndex(where: { $0.id == aid }) else { return }
        threads[idx].messages = Array(messages.suffix(Self.persistedHistoryCap))
        threads[idx].updatedAt = Date()
        autoTitleIfNeeded(at: idx)
        persistThreads()
    }

    private func persistThreads() {
        // Sort newest-first, cap, encode. Archived threads age out
        // first when over the cap so the active set stays in the
        // foreground.
        threads.sort { lhs, rhs in
            if lhs.isArchived != rhs.isArchived { return !lhs.isArchived && rhs.isArchived }
            return lhs.updatedAt > rhs.updatedAt
        }
        let trimmed = Array(threads.prefix(Self.persistedThreadCap))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        UserDefaults.standard.set(data, forKey: Self.threadsKey)
        if let aid = activeThreadID {
            UserDefaults.standard.set(aid.uuidString, forKey: Self.activeThreadKey)
        }
    }

    // MARK: Thread CRUD

    /// Creates a new thread and makes it active. The current thread's
    /// messages are saved first.
    @discardableResult
    func newThread() -> ChatThread {
        persistActiveThread()
        let t = ChatThread(title: ChatThread.defaultTitle)
        threads.insert(t, at: 0)
        activeThreadID = t.id
        messages = []
        error = nil
        persistThreads()
        return t
    }

    /// Switches to an existing thread. The previous thread's messages
    /// are saved before the swap.
    func selectThread(_ id: UUID) {
        guard id != activeThreadID else { return }
        persistActiveThread()
        activeThreadID = id
        messages = threads.first(where: { $0.id == id })?.messages ?? []
        error = nil
        persistThreads()
    }

    /// Deletes a thread permanently. If it was active, switches to
    /// the next available thread, or leaves the chat empty if none.
    func deleteThread(_ id: UUID) {
        threads.removeAll { $0.id == id }
        if activeThreadID == id {
            activeThreadID = threads.first?.id
            messages = threads.first(where: { $0.id == activeThreadID })?.messages ?? []
        }
        persistThreads()
    }

    /// Toggles archive state. Archived threads still exist and can be
    /// unarchived; they just sink to the bottom of the list.
    func toggleArchive(_ id: UUID) {
        guard let idx = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[idx].isArchived.toggle()
        persistThreads()
    }

    // MARK: Auto-title

    /// First user message becomes the thread title once it's clear
    /// what the conversation is about. Caps at 40 chars; legacy
    /// migration uses the same helper to derive a sensible title.
    private static let autoTitleLimit = 40

    private func autoTitleIfNeeded(at index: Int) {
        guard threads[index].title == ChatThread.defaultTitle else { return }
        if let derived = autoTitle(from: threads[index].messages) {
            threads[index].title = derived
        }
    }

    private func autoTitle(from messages: [ChatMessage]) -> String? {
        guard let firstUser = messages.first(where: { $0.role == .user }) else { return nil }
        let trimmed = firstUser.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= Self.autoTitleLimit { return trimmed }
        return String(trimmed.prefix(Self.autoTitleLimit)) + "…"
    }

    /// Ensures there's an active thread before the first message is
    /// sent. Called from `send()` so the user doesn't have to tap
    /// "new" explicitly on a cold launch.
    private func ensureActiveThread() {
        if activeThreadID == nil {
            newThread()
        }
    }

    func send(userText: String, context: String) async {
        guard !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Phase 8 / AI v2: ensure the user is in a thread before the
        // first message lands. Cold launch with no threads triggers
        // implicit creation here so the user can just start typing.
        ensureActiveThread()

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

        // Save the active thread's mutated messages back to the
        // threads array + disk now that streaming is done. Skipping
        // the per-token persist saved a ~hundred re-encodes; doing
        // it once at the end keeps the on-disk state durable.
        persistActiveThread()

        // Suppress the placeholder warning — the optimistic ID isn't
        // used downstream, but Swift's unused-let lint will complain
        // without something referencing it.
        _ = placeholderID
    }

    /// Clears the *active* thread's messages (not all threads). The
    /// thread itself remains; only its conversation history is wiped.
    /// To remove a thread entirely use `deleteThread(_:)`.
    func clearHistory() {
        messages = []
        error = nil
        persistActiveThread()
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
    @State private var showThreadList = false
    @FocusState private var inputFocused: Bool

    /// Active thread title for the navigation bar. Falls back to
    /// "Aski AI" when there are no threads yet (cold launch).
    private var activeThreadTitle: String {
        guard let aid = service.activeThreadID,
              let t = service.threads.first(where: { $0.id == aid }) else {
            return "Aski AI"
        }
        return t.title
    }

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
            .navigationTitle(activeThreadTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: { Text("Done") }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    // Phase 8 / AI v2 — thread management.
                    // Threads sheet: switch between parallel conversations.
                    Button { showThreadList = true } label: {
                        Image(systemName: "bubble.left.and.bubble.right")
                    }
                    // New thread shortcut. Always enabled — distinct from
                    // clearHistory which wipes the active thread.
                    Button { service.newThread() } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    // Clear active thread (renamed from "history" because
                    // it now scopes to one thread, not the whole app).
                    Button {
                        service.clearHistory()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .disabled(service.messages.isEmpty)
                }
            }
            .sheet(isPresented: $showThreadList) {
                ThreadListSheet(service: service)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
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
        // Phase 8 / Inventory v1 — surface inventory + procurement
        // prompts when there's something useful for the AI to talk about.
        let pendingMRs = store.materialRequests.filter {
            !$0.isDeleted && $0.status == .submitted
        }
        if !pendingMRs.isEmpty {
            prompts.append("What material requests are awaiting approval?")
        }
        // Phase 8 / Inventory v2 — switched to reorder-point-aware
        // detection. Surfaces items BEFORE they hit zero so the user
        // can act ahead of a stockout.
        if !store.lowStockItems.isEmpty {
            prompts.append("Which inventory items are running low?")
        }
        prompts.append("Which crews are on site today?")
        prompts.append("Give me a project status overview")
        return Array(prompts.prefix(5))
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

        // Procurement — Material Requests + Purchase Orders
        let openMRs = materialRequests.filter { !$0.isDeleted && $0.status.isOpen }
        let pendingApprovalMRs = materialRequests.filter { !$0.isDeleted && $0.status == .submitted }
        let openPOs = purchaseOrders.filter { !$0.isDeleted && $0.status.isOpen }
        lines += [
            "",
            "=== PROCUREMENT ===",
            "Open material requests: \(openMRs.count) (\(pendingApprovalMRs.count) awaiting approval)",
            "Open purchase orders: \(openPOs.count)",
        ]
        if !pendingApprovalMRs.isEmpty {
            let preview = pendingApprovalMRs.prefix(3)
                .map { "\($0.requestNumber) — \($0.estimatedTotal.currencyString)" }
                .joined(separator: ", ")
            lines.append("Pending MRs: \(preview)")
        }

        // Phase 8 / Inventory v2 — low-stock detection via per-item
        // reorder threshold (with v1 qty≤0 fallback for items without
        // a configured point). Replaces the v1 "out of stock" line
        // with a richer "low stock at threshold" signal so the AI can
        // surface items BEFORE they hit zero.
        let activeItems = inventoryItems.filter { !$0.isDeleted && $0.isActive }
        let lowStock = lowStockItems
        let totalStockValue: Decimal = inventoryStockLevels
            .filter { !$0.isDeleted }
            .reduce(0) { acc, level in
                acc + (level.quantityOnHand * (level.avgUnitCost ?? 0))
            }
        let recentTransfers = recentInventoryTransfers.prefix(5)
        lines += [
            "",
            "=== INVENTORY ===",
            "Catalog: \(activeItems.count) active items across \(activeStockLocations.count) locations",
            "Items at or below reorder point: \(lowStock.count) of \(activeItems.count)",
            "Estimated stock value: \(totalStockValue.currencyString)",
        ]
        if !lowStock.isEmpty {
            let preview = lowStock.prefix(5).map { item -> String in
                let onHand = totalQuantityOnHand(itemID: item.id)
                if let rp = item.reorderPoint {
                    return "\(item.name) (\(onHand)/\(rp) \(item.unit))"
                }
                return "\(item.name) (\(onHand) \(item.unit))"
            }.joined(separator: ", ")
            lines.append("Low stock: \(preview)")
        }
        if !recentTransfers.isEmpty {
            lines.append("Recent movements (\(recentTransfers.count)):")
            for t in recentTransfers {
                let item = activeItems.first { $0.id == t.itemID }?.name ?? "(unknown item)"
                lines.append("  • \(t.transferNumber) — \(t.quantity) of \(item)")
            }
        }

        // Contracts + Sub-Contracts (safety / compliance signal)
        let activeContracts = contracts.filter { !$0.isDeleted && $0.status != .terminated }
        let activeSubContracts = subContracts.filter { !$0.isDeleted }
        if !activeContracts.isEmpty || !activeSubContracts.isEmpty {
            lines += [
                "",
                "=== CONTRACTS ===",
                "Active contracts: \(activeContracts.count)",
                "Active sub-contracts: \(activeSubContracts.count)",
            ]
        }

        if let weather = currentWeather {
            lines += ["", "=== WEATHER ===", "\(weather.tempString), \(weather.conditionText). Wind: \(weather.windString)"]
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Thread List Sheet
//
// Phase 8 / AI v2 — sidebar / picker for switching between parallel
// conversations. Sorted active-first, newest-first. Each row shows
// title + preview + last-activity timestamp. Swipe-to-delete on the
// inactive rows; swipe-to-archive toggle on both.

struct ThreadListSheet: View {
    @ObservedObject var service: AIChatService
    @Environment(\.dismiss) var dismiss

    private var activeThreads: [ChatThread] {
        service.threads.filter { !$0.isArchived }
    }

    private var archivedThreads: [ChatThread] {
        service.threads.filter { $0.isArchived }
    }

    var body: some View {
        NavigationStack {
            List {
                if activeThreads.isEmpty {
                    emptyState
                } else {
                    Section("Conversations (\(activeThreads.count))") {
                        ForEach(activeThreads) { thread in
                            threadRow(thread, isArchived: false)
                        }
                    }
                }
                if !archivedThreads.isEmpty {
                    Section("Archived (\(archivedThreads.count))") {
                        ForEach(archivedThreads) { thread in
                            threadRow(thread, isArchived: true)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Conversations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        service.newThread()
                        dismiss()
                    } label: {
                        Label("New", systemImage: "square.and.pencil")
                    }
                }
            }
        }
    }

    private func threadRow(_ thread: ChatThread, isArchived: Bool) -> some View {
        let isActive = thread.id == service.activeThreadID
        return Button {
            service.selectThread(thread.id)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if isActive {
                            Circle().fill(Color.blue).frame(width: 6, height: 6)
                        }
                        Text(thread.title)
                            .font(.subheadline).bold()
                            .foregroundColor(isArchived ? .secondary : .primary)
                            .lineLimit(1)
                    }
                    Text(thread.preview)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Text(thread.updatedAt.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if isActive {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                service.deleteThread(thread.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                service.toggleArchive(thread.id)
            } label: {
                Label(isArchived ? "Unarchive" : "Archive",
                      systemImage: isArchived ? "tray.and.arrow.up" : "archivebox")
            }
            .tint(.orange)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("No conversations yet")
                .font(.headline)
            Text("Start a new one — your chats are saved here and survive cold launches.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .listRowBackground(Color.clear)
    }
}
