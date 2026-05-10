// SyncErrorMapperTests.swift
// Aski IQ — Phase 5 / Wave 1 unit tests for the Phase 2 error-visibility
// surface. Pure Swift — no Supabase mock or network needed.

import XCTest
@testable import BV_APP

final class SyncErrorMapperTests: XCTestCase {

    // MARK: - Helpers

    /// Build a synthetic Error whose `localizedDescription` carries the
    /// given string. Mimics what Supabase Swift SDK produces when a push
    /// fails — the SDK wraps the PostgREST JSON body in an Error whose
    /// localizedDescription contains the SQLSTATE / message text.
    private struct SyntheticError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func error(_ message: String) -> Error {
        SyntheticError(message: message)
    }

    // MARK: - Aski-IQ-specific patterns (highest priority)

    func test_opportunityIdNullPattern_maps_to_unlinked_opportunity_message() {
        let info = SyncErrorMapper.info(for: error(
            #"null value in column "opportunity_id" of relation "material_requests" violates not-null constraint"#
        ))
        XCTAssertEqual(info.code, "23502")
        XCTAssertTrue(info.reason.lowercased().contains("opportunity"),
                      "Expected reason to mention opportunity link; got: \(info.reason)")
    }

    func test_singleDestinationCheckPattern_maps_to_destination_message() {
        let info = SyncErrorMapper.info(for: error(
            #"new row violates check constraint "material_requests_single_destination_check""#
        ))
        XCTAssertEqual(info.code, "23514")
        XCTAssertTrue(info.reason.lowercased().contains("destination"),
                      "Expected reason to mention destination; got: \(info.reason)")
    }

    func test_companyRequestNumberUnique_maps_to_duplicate_number_message() {
        let info = SyncErrorMapper.info(for: error(
            #"duplicate key value violates unique constraint "material_requests_company_request_number_unique""#
        ))
        XCTAssertEqual(info.code, "23505")
        XCTAssertTrue(info.reason.lowercased().contains("duplicate") || info.reason.lowercased().contains("number"),
                      "Expected reason to mention duplicate or number; got: \(info.reason)")
    }

    func test_companyPONumberUnique_maps_to_duplicate_number_message() {
        let info = SyncErrorMapper.info(for: error(
            #"duplicate key value violates unique constraint "purchase_orders_company_po_number_unique""#
        ))
        XCTAssertEqual(info.code, "23505")
        XCTAssertTrue(info.reason.lowercased().contains("duplicate") || info.reason.lowercased().contains("number"))
    }

    // MARK: - Generic SQLSTATE codes

    func test_genericNotNull_23502_maps_to_missing_field_message() {
        let info = SyncErrorMapper.info(for: error(
            #"{"code":"23502","message":"null value in column \"foo\""}"#
        ))
        XCTAssertEqual(info.code, "23502")
        XCTAssertTrue(info.reason.lowercased().contains("missing") || info.reason.lowercased().contains("required"),
                      "Got: \(info.reason)")
    }

    func test_genericForeignKey_23503_maps_to_linked_record_message() {
        let info = SyncErrorMapper.info(for: error(
            #"{"code":"23503","message":"foreign key violation"}"#
        ))
        XCTAssertEqual(info.code, "23503")
        XCTAssertTrue(info.reason.lowercased().contains("linked") || info.reason.lowercased().contains("synced"),
                      "Got: \(info.reason)")
    }

    func test_genericUnique_23505_maps_to_duplicate_message() {
        let info = SyncErrorMapper.info(for: error(
            #"{"code":"23505","message":"duplicate key value"}"#
        ))
        XCTAssertEqual(info.code, "23505")
        XCTAssertTrue(info.reason.lowercased().contains("duplicate") || info.reason.lowercased().contains("conflict"),
                      "Got: \(info.reason)")
    }

    func test_genericCheck_23514_maps_to_invalid_combo_message() {
        let info = SyncErrorMapper.info(for: error(
            #"{"code":"23514","message":"check constraint violation"}"#
        ))
        XCTAssertEqual(info.code, "23514")
        XCTAssertTrue(info.reason.lowercased().contains("valid") || info.reason.lowercased().contains("combination") || info.reason.lowercased().contains("field"),
                      "Got: \(info.reason)")
    }

    func test_permissionDenied_42501_maps_to_permission_message() {
        let info = SyncErrorMapper.info(for: error(
            #"{"code":"42501","message":"insufficient privilege"}"#
        ))
        XCTAssertEqual(info.code, "42501")
        XCTAssertTrue(info.reason.lowercased().contains("permission"))
    }

    func test_columnDoesNotExist_42703_maps_to_schema_cache_message() {
        let info = SyncErrorMapper.info(for: error(
            #"{"code":"42703","message":"column \"foo\" does not exist"}"#
        ))
        XCTAssertEqual(info.code, "42703")
        XCTAssertTrue(info.reason.lowercased().contains("schema") || info.reason.lowercased().contains("cache"),
                      "Got: \(info.reason)")
    }

    // MARK: - Auth / connectivity

    func test_jwtExpired_maps_to_session_message() {
        let info = SyncErrorMapper.info(for: error("JWT token expired"))
        XCTAssertEqual(info.code, "AUTH")
        XCTAssertTrue(info.reason.lowercased().contains("session") || info.reason.lowercased().contains("sign"))
    }

    func test_pgrst301_maps_to_session_message() {
        let info = SyncErrorMapper.info(for: error("PGRST301: invalid token"))
        XCTAssertEqual(info.code, "AUTH")
    }

    func test_networkOffline_maps_to_offline_message() {
        let info = SyncErrorMapper.info(for: error("network connection timed out"))
        XCTAssertEqual(info.code, "OFFLINE")
        XCTAssertTrue(info.reason.lowercased().contains("network") || info.reason.lowercased().contains("connection"))
    }

    func test_couldNotConnect_maps_to_offline_message() {
        let info = SyncErrorMapper.info(for: error("could not connect to host"))
        XCTAssertEqual(info.code, "OFFLINE")
    }

    // MARK: - Fallback paths

    func test_unknownShortError_uses_localizedDescription_as_reason() {
        // Short, non-empty localizedDescription gets passed through verbatim
        // so users see something specific instead of generic "sync failed."
        let info = SyncErrorMapper.info(for: error("Specific small error"))
        XCTAssertEqual(info.code, "")
        XCTAssertEqual(info.reason, "Specific small error")
    }

    func test_unknownLongError_uses_generic_message() {
        // Very long error strings (~ > 160 chars) fall back to generic copy
        // because they'd flood the row and probably aren't human-readable.
        let longMessage = String(repeating: "x", count: 200)
        let info = SyncErrorMapper.info(for: error(longMessage))
        XCTAssertEqual(info.code, "")
        XCTAssertTrue(info.reason.lowercased().contains("support") || info.reason.lowercased().contains("failed"),
                      "Got: \(info.reason)")
    }

    // MARK: - Specificity ordering — Aski-specific beats generic

    func test_opportunityIdPattern_takes_precedence_over_generic_23502() {
        // Both patterns match (the message has a SQLSTATE-shaped code AND
        // mentions opportunity_id). Aski-specific should win because its
        // user message is more actionable.
        let info = SyncErrorMapper.info(for: error(
            #"{"code":"23502","message":"null value in column \"opportunity_id\" of relation \"material_requests\""}"#
        ))
        XCTAssertEqual(info.code, "23502")
        XCTAssertTrue(info.reason.lowercased().contains("opportunity"),
                      "Aski-specific opportunity_id message should win over generic 23502; got: \(info.reason)")
    }

    // MARK: - SyncErrorInfo struct

    func test_SyncErrorInfo_init_records_timestamp() {
        let before = Date()
        let info = SyncErrorInfo(code: "X", reason: "y", rawMessage: "z")
        let after = Date()
        XCTAssertGreaterThanOrEqual(info.timestamp, before)
        XCTAssertLessThanOrEqual(info.timestamp, after)
    }

    func test_SyncErrorInfo_equality_ignores_timestamp_difference() {
        let a = SyncErrorInfo(code: "X", reason: "y", rawMessage: "z", timestamp: Date(timeIntervalSince1970: 1))
        let b = SyncErrorInfo(code: "X", reason: "y", rawMessage: "z", timestamp: Date(timeIntervalSince1970: 2))
        // Equatable is auto-derived; timestamps differ so these are NOT
        // equal. Documenting the current behavior — if we want
        // timestamp-insensitive equality later, override == manually.
        XCTAssertNotEqual(a, b)
    }
}
