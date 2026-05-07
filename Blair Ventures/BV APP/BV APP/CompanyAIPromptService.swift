// CompanyAIPromptService.swift
// Aski IQ — Per-company AI system-prompt customization (deferred Phase 2).
//
// WHY THIS EXISTS
// The four user-facing AI surfaces (Aski Chat, contract review,
// contract diff, CRM pre-call brief) all use hard-coded system
// prompts. The 2026-04 audit deferred per-company customization to
// Phase 2 — this is the closeout.
//
// SHAPE
//   surface  ─ enum value (chat / contractReview / contractDiff / crmBrief)
//   prompt   ─ raw replacement system prompt string. Empty / nil →
//              caller falls back to the iOS-side default.
//
// FLOW
//   * `fetchAll()` reads `companies.ai_prompt_overrides` via
//     `get_my_company_ai_prompts()` RPC. Returns a typed dict keyed
//     by `Surface`.
//   * `set(surface:prompt:)` writes one surface via
//     `set_company_ai_prompt()` RPC. Server gates on admin role.
//   * `effectivePrompt(for:fallback:)` returns the override when set,
//     otherwise the iOS default. AI services call this once at the
//     top of every send.
//
// CACHING
// `cached` keeps the last fetch in memory so AI services don't hit
// Supabase before every call. Refreshed on every successful `set`.
// The cache is per-tenant (cleared on sign-out via clearCache()).

import Foundation
import Combine
import Supabase

@MainActor
final class CompanyAIPromptService: ObservableObject {

    static let shared = CompanyAIPromptService()
    private init() {}

    // MARK: - Surfaces

    /// AI surfaces that admins can customize. Adding a new surface
    /// means: (a) extending this enum, (b) adding the matching CHECK
    /// branch in the `set_company_ai_prompt()` RPC server-side,
    /// (c) wiring the calling AI service to use `effectivePrompt(...)`.
    enum Surface: String, CaseIterable, Identifiable {
        case chat            = "chat"
        case contractReview  = "contract_review"
        case contractDiff    = "contract_diff"
        case crmBrief        = "crm_brief"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .chat:           return "Aski Chat"
            case .contractReview: return "Contract Review"
            case .contractDiff:   return "Contract Diff"
            case .crmBrief:       return "CRM Pre-Call Brief"
            }
        }

        var helperText: String {
            switch self {
            case .chat:
                return "System prompt for the conversational assistant. Sets tone, business context, and what data Aski has access to."
            case .contractReview:
                return "How AI Review parses and scores contract risk. Override to inject industry-specific clauses or jurisdiction context."
            case .contractDiff:
                return "How AI Diff describes changes between contract versions. Override to emphasise the language your reviewers care about."
            case .crmBrief:
                return "How AI summarises a CRM contact before a call. Override to bake in your sales playbook or qualification framework."
            }
        }
    }

    // MARK: - Errors

    enum PromptError: Error, LocalizedError {
        case notAdmin
        case unknownSurface
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .notAdmin:        return "Only admins can change AI prompts."
            case .unknownSurface:  return "That AI surface isn't recognised by the server."
            case .underlying(let e): return e.localizedDescription
            }
        }
    }

    // MARK: - State

    /// Last-known overrides. Empty until `fetchAll()` runs once.
    @Published private(set) var cached: [Surface: String] = [:]

    /// True while a fetch is in flight. UI binds for spinner.
    @Published var isFetching = false

    // MARK: - Reads

    /// Pulls the JSONB blob and decodes into the typed dict. Best-
    /// effort — transport errors leave `cached` untouched, so AI calls
    /// keep working with the prior value (or the iOS default).
    @discardableResult
    func fetchAll() async -> [Surface: String] {
        isFetching = true
        defer { isFetching = false }
        do {
            // Postgres returns the JSONB column as a [String: String]
            // when the JSONB shape is { "key": "value", ... }. Anyone
            // who hand-wrote a non-string value into the column is
            // out of luck — we drop those entries rather than crash.
            let raw: [String: String] = try await supabase
                .rpc("get_my_company_ai_prompts")
                .execute()
                .value
            var typed: [Surface: String] = [:]
            for (k, v) in raw {
                if let s = Surface(rawValue: k), !v.isEmpty {
                    typed[s] = v
                }
            }
            cached = typed
            return typed
        } catch {
            print("⚠️ CompanyAIPromptService.fetchAll failed: \(error)")
            return cached
        }
    }

    // MARK: - Writes

    /// Sets one surface's prompt. Pass empty string to revert to the
    /// iOS-side default (server removes the JSON key).
    func set(surface: Surface, prompt: String) async throws {
        struct Params: Encodable {
            let p_surface: String
            let p_prompt:  String
        }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await supabase
                .rpc("set_company_ai_prompt",
                     params: Params(p_surface: surface.rawValue, p_prompt: trimmed))
                .execute()

            // Refresh local cache so the next AI call uses the new value.
            if trimmed.isEmpty {
                cached.removeValue(forKey: surface)
            } else {
                cached[surface] = trimmed
            }
        } catch {
            let m = error.localizedDescription.lowercased()
            if m.contains("admin role required") || m.contains("42501") {
                throw PromptError.notAdmin
            }
            if m.contains("unknown ai surface") {
                throw PromptError.unknownSurface
            }
            throw PromptError.underlying(error)
        }
    }

    // MARK: - Resolve effective prompt

    /// Returns the company override for this surface if set, otherwise
    /// the supplied iOS default. Call once at the top of every AI
    /// request so a customization made on iPad A is picked up by the
    /// next call from iPhone B (assuming `fetchAll()` has run, which
    /// it does on every login + on every Settings open).
    func effectivePrompt(for surface: Surface, fallback: String) -> String {
        if let override = cached[surface], !override.isEmpty {
            return override
        }
        return fallback
    }

    // MARK: - Lifecycle

    /// Clears the in-memory cache. Call on sign-out so a different
    /// tenant signing in next doesn't see the previous tenant's
    /// prompts. (Realistically the next fetchAll() also overwrites,
    /// but defence-in-depth.)
    func clearCache() {
        cached.removeAll()
    }
}
