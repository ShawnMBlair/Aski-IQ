// CompanyAILimitsService.swift
// Aski IQ — Per-company AI spending caps + per-user rate limit overrides.
//
// Pairs with `CompanyAIKeyService` (which manages the Vault-backed BYOK
// key) and the ai-proxy Edge Function v3 (which enforces these limits
// server-side on every AI call). Reads/writes go through SECURITY
// DEFINER RPCs so admins can change limits, members can only read.
//
// SHAPE
//
//   CompanyAILimits — full spending-cap settings + today/month usage
//   UsageQuotaState  — UI helper: percent used, ceiling source, breached?
//
// All cost values are in CENTS to avoid floating-point drift between the
// Edge Function (which writes them as integers) and the Swift UI.

import Foundation
import Supabase

@MainActor
final class CompanyAILimitsService {

    static let shared = CompanyAILimitsService()
    private init() {}

    // MARK: - Models

    /// Server-side returns the limit row joined with computed today/month
    /// usage rollups. Limits use `nil` to mean "no cap on that axis".
    struct CompanyAILimits: Decodable, Equatable {
        var dailyTokenLimit:           Int64?
        var monthlyTokenLimit:         Int64?
        var dailyCostLimitCents:       Int64?
        var monthlyCostLimitCents:     Int64?
        var aiPauseWhenExceeded:       Bool
        var aiAdminNotificationEnabled: Bool

        var todayRequestCount:  Int64
        var todayInputTokens:   Int64
        var todayOutputTokens:  Int64
        var todayCostCents:     Int64
        var monthRequestCount:  Int64
        var monthInputTokens:   Int64
        var monthOutputTokens:  Int64
        var monthCostCents:     Int64

        // Computed convenience
        var todayTokens: Int64 { todayInputTokens + todayOutputTokens }
        var monthTokens: Int64 { monthInputTokens + monthOutputTokens }

        enum CodingKeys: String, CodingKey {
            case dailyTokenLimit            = "daily_token_limit"
            case monthlyTokenLimit          = "monthly_token_limit"
            case dailyCostLimitCents        = "daily_cost_limit_cents"
            case monthlyCostLimitCents      = "monthly_cost_limit_cents"
            case aiPauseWhenExceeded        = "ai_pause_when_exceeded"
            case aiAdminNotificationEnabled = "ai_admin_notification_enabled"
            case todayRequestCount          = "today_request_count"
            case todayInputTokens           = "today_input_tokens"
            case todayOutputTokens          = "today_output_tokens"
            case todayCostCents             = "today_cost_cents"
            case monthRequestCount          = "month_request_count"
            case monthInputTokens           = "month_input_tokens"
            case monthOutputTokens          = "month_output_tokens"
            case monthCostCents             = "month_cost_cents"
        }
    }

    enum LimitsError: Error, LocalizedError {
        case notAdmin
        case underlying(Error)
        var errorDescription: String? {
            switch self {
            case .notAdmin:        return "Only company admins can change AI limits."
            case .underlying(let e): return e.localizedDescription
            }
        }
    }

    // MARK: - Reads

    /// Any signed-in member can read the company's limits + usage.
    func fetchLimits() async throws -> CompanyAILimits? {
        do {
            let rows: [CompanyAILimits] = try await supabase
                .rpc("get_company_ai_limits")
                .execute()
                .value
            return rows.first
        } catch {
            throw LimitsError.underlying(error)
        }
    }

    // MARK: - Writes (admin only — server enforces)

    /// Update the company's spending-cap settings. Pass nil for any axis
    /// where you want no cap.
    func setLimits(
        dailyTokenLimit:           Int64?,
        monthlyTokenLimit:         Int64?,
        dailyCostLimitCents:       Int64?,
        monthlyCostLimitCents:     Int64?,
        pauseWhenExceeded:         Bool,
        adminNotificationEnabled:  Bool
    ) async throws {
        struct Params: Encodable {
            let p_daily_token_limit:           Int64?
            let p_monthly_token_limit:         Int64?
            let p_daily_cost_limit_cents:      Int64?
            let p_monthly_cost_limit_cents:    Int64?
            let p_pause_when_exceeded:         Bool
            let p_admin_notification_enabled:  Bool
        }
        do {
            try await supabase
                .rpc("set_company_ai_limits", params: Params(
                    p_daily_token_limit:          dailyTokenLimit,
                    p_monthly_token_limit:        monthlyTokenLimit,
                    p_daily_cost_limit_cents:     dailyCostLimitCents,
                    p_monthly_cost_limit_cents:   monthlyCostLimitCents,
                    p_pause_when_exceeded:        pauseWhenExceeded,
                    p_admin_notification_enabled: adminNotificationEnabled
                ))
                .execute()
        } catch {
            let m = error.localizedDescription.lowercased()
            if m.contains("admin role required") || m.contains("42501") {
                throw LimitsError.notAdmin
            }
            throw LimitsError.underlying(error)
        }
    }

    /// Per-user rate-limit override + optional block window. Nil clears
    /// the override and reverts the user to the role default.
    func setUserLimits(
        userID:            UUID,
        requestsPerMinute: Int?,
        tokensPerDay:      Int64?,
        blockedUntil:      Date?,
        blockedReason:     String?
    ) async throws {
        struct Params: Encodable {
            let p_user_id:              UUID
            let p_requests_per_minute:  Int?
            let p_tokens_per_day:       Int64?
            let p_blocked_until:        Date?
            let p_blocked_reason:       String?
        }
        do {
            try await supabase
                .rpc("set_user_ai_limits", params: Params(
                    p_user_id:             userID,
                    p_requests_per_minute: requestsPerMinute,
                    p_tokens_per_day:      tokensPerDay,
                    p_blocked_until:       blockedUntil,
                    p_blocked_reason:      blockedReason
                ))
                .execute()
        } catch {
            let m = error.localizedDescription.lowercased()
            if m.contains("admin role required") || m.contains("42501") {
                throw LimitsError.notAdmin
            }
            throw LimitsError.underlying(error)
        }
    }
}

// MARK: - UI helpers

extension CompanyAILimitsService.CompanyAILimits {
    /// Cost in dollars (cents / 100), rounded to 2 decimals for display.
    var todayCostDollars:  Decimal { Decimal(todayCostCents) / 100 }
    var monthCostDollars:  Decimal { Decimal(monthCostCents) / 100 }

    /// Percent of daily token cap consumed (0.0 — 1.0+). nil = uncapped.
    var dailyTokenPctUsed: Double? {
        guard let cap = dailyTokenLimit, cap > 0 else { return nil }
        return Double(todayTokens) / Double(cap)
    }
    var monthlyTokenPctUsed: Double? {
        guard let cap = monthlyTokenLimit, cap > 0 else { return nil }
        return Double(monthTokens) / Double(cap)
    }
    var dailyCostPctUsed: Double? {
        guard let cap = dailyCostLimitCents, cap > 0 else { return nil }
        return Double(todayCostCents) / Double(cap)
    }
    var monthlyCostPctUsed: Double? {
        guard let cap = monthlyCostLimitCents, cap > 0 else { return nil }
        return Double(monthCostCents) / Double(cap)
    }

    /// True if any cap is at or beyond 100% — drives the warning UI.
    var anyCapBreached: Bool {
        [dailyTokenPctUsed, monthlyTokenPctUsed, dailyCostPctUsed, monthlyCostPctUsed]
            .compactMap { $0 }
            .contains(where: { $0 >= 1.0 })
    }
}
