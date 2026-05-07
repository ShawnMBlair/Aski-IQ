// SampleDataParser.swift
// Aski IQ — JSON-backed sample dataset reader.
//
// The canonical sample dataset is the Excel workbook
// AskiIQ_SampleData_v1.0.xlsx. At build time it's exported to
// AskiIQ_SampleData_v1.0.json (the bundled resource this parser reads).
//
// The same parser is also reused by ImportService for end-user imports —
// the only difference is the persistence layer doesn't stamp
// `is_sample_data = true` for real imports.

import Foundation

// MARK: - Raw dataset shape

struct ParsedDataset: Decodable {
    let manifest: Manifest
    let tabs:     [String: [Row]]

    typealias Row = [String: SampleAnyJSON]

    struct Manifest: Decodable {
        let seedVersion:           String
        let datasetName:           String
        let description:           String?
        let compatibleAppVersion:  String
        let expectedCounts:        [String: Int]
        let currencyDefault:       String?
        let taxRateDefault:        Double?

        private enum CodingKeys: String, CodingKey {
            case seedVersion           = "seed_version"
            case datasetName           = "dataset_name"
            case description
            case compatibleAppVersion  = "compatible_app_version"
            case expectedCounts        = "expected_counts"
            case currencyDefault       = "currency_default"
            case taxRateDefault        = "tax_rate_default"
        }

        // tax_rate_default may arrive as a string in the manifest; coerce.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.seedVersion          = try c.decode(String.self, forKey: .seedVersion)
            self.datasetName          = try c.decode(String.self, forKey: .datasetName)
            self.description          = try c.decodeIfPresent(String.self, forKey: .description)
            self.compatibleAppVersion = try c.decode(String.self, forKey: .compatibleAppVersion)
            self.expectedCounts       = try c.decode([String: Int].self, forKey: .expectedCounts)
            self.currencyDefault      = try c.decodeIfPresent(String.self, forKey: .currencyDefault)
            if let s = try? c.decode(String.self, forKey: .taxRateDefault) {
                self.taxRateDefault = Double(s)
            } else {
                self.taxRateDefault = try c.decodeIfPresent(Double.self, forKey: .taxRateDefault)
            }
        }
    }
}

// MARK: - SampleAnyJSON

/// Minimal type-erased JSON value so the parser can decode mixed-shape
/// rows without per-tab models. Higher layers cast via accessors.
enum SampleAnyJSON: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case integer(Int)
    case string(String)
    case array([SampleAnyJSON])
    case object([String: SampleAnyJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()                                         { self = .null }
        else if let v = try? c.decode(Bool.self)                 { self = .bool(v) }
        else if let v = try? c.decode(Int.self)                  { self = .integer(v) }
        else if let v = try? c.decode(Double.self)               { self = .number(v) }
        else if let v = try? c.decode(String.self)               { self = .string(v) }
        else if let v = try? c.decode([SampleAnyJSON].self)            { self = .array(v) }
        else if let v = try? c.decode([String: SampleAnyJSON].self)    { self = .object(v) }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "SampleAnyJSON decode failed")
        }
    }

    // Accessors — return nil on type mismatch
    var stringValue: String? {
        if case .string(let s) = self { return s }; return nil
    }
    var boolValue: Bool? {
        if case .bool(let b) = self { return b }; return nil
    }
    var intValue: Int? {
        switch self {
        case .integer(let i): return i
        case .number(let d):  return Int(d)
        case .string(let s):  return Int(s)
        default:              return nil
        }
    }
    var doubleValue: Double? {
        switch self {
        case .number(let d):  return d
        case .integer(let i): return Double(i)
        case .string(let s):  return Double(s)
        default:              return nil
        }
    }
    var decimalValue: Decimal? {
        switch self {
        case .number(let d):  return Decimal(d)
        case .integer(let i): return Decimal(i)
        case .string(let s):  return Decimal(string: s)
        default:              return nil
        }
    }
    var arrayValue: [SampleAnyJSON]? {
        if case .array(let a) = self { return a }; return nil
    }
    var objectValue: [String: SampleAnyJSON]? {
        if case .object(let o) = self { return o }; return nil
    }
    var isNull: Bool {
        if case .null = self { return true }; return false
    }
}

// MARK: - Row helpers

extension Dictionary where Key == String, Value == SampleAnyJSON {

    /// Lookup the unique row key (`__ref`).
    var ref: String? { self["__ref"]?.stringValue }

    /// Get a string field, treating empty string as nil.
    func string(_ key: String) -> String? {
        guard let v = self[key]?.stringValue, !v.isEmpty else { return nil }
        return v
    }

    func bool(_ key: String) -> Bool?       { self[key]?.boolValue }
    func int(_ key: String) -> Int?         { self[key]?.intValue }
    func double(_ key: String) -> Double?   { self[key]?.doubleValue }
    func decimal(_ key: String) -> Decimal? { self[key]?.decimalValue }

    /// Resolve a `_ref` (FK) column to its target __ref string. Caller
    /// then asks the resolver to map that __ref to an actual UUID.
    func refField(_ key: String) -> String? { string(key) }

    /// Comma-separated `_refs` list (e.g., `memberIDs_refs = "emp.a,emp.b"`).
    func refList(_ key: String) -> [String] {
        guard let raw = string(key) else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Resolve a `_rel` relative-date column. Returns nil if absent.
    /// Tokens: `T0`, `T-N`, `T+N` resolve relative to `now`. Bare ISO 8601
    /// strings fall through to ISO8601DateFormatter.
    func relativeDate(_ key: String, now: Date = Date()) throws -> Date? {
        guard let raw = string(key) else { return nil }
        return try RelativeDate.resolve(raw, relativeTo: now)
    }

    /// Resolve an enum field — accepts the lowercase Swift-case name.
    func swiftEnum<E: RawRepresentable>(_ key: String, type: E.Type) -> E? where E.RawValue == String {
        guard let raw = string(key) else { return nil }
        return E(rawValue: raw)
    }
}

// MARK: - Relative date resolver

enum RelativeDate {

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoDateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func resolve(_ token: String, relativeTo now: Date) throws -> Date {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        // T0 / T+N / T-N
        if trimmed.hasPrefix("T") {
            let body = String(trimmed.dropFirst())
            let days: Int
            if body == "0" || body.isEmpty {
                days = 0
            } else if let n = Int(body) {
                days = n
            } else {
                throw SampleDataError.relativeDateMalformed(token: token)
            }
            return Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
        }
        // ISO 8601 with time
        if let d = isoFormatter.date(from: trimmed) { return d }
        // ISO date only
        if let d = isoDateOnly.date(from: trimmed) { return d }
        throw SampleDataError.relativeDateMalformed(token: token)
    }
}

// MARK: - SampleDataParser

@MainActor
struct SampleDataParser {

    /// Path to the embedded JSON resource. Override for tests.
    static let defaultResourceName = "AskiIQ_SampleData_v1.0"

    /// Load and decode the bundled dataset.
    static func loadEmbedded(name: String = defaultResourceName) throws -> ParsedDataset {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json") else {
            throw SampleDataError.datasetMissing
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(ParsedDataset.self, from: data)
        } catch {
            throw SampleDataError.datasetUnreadable(underlying: error)
        }
    }

    /// Validate the dataset's manifest before any inserts run.
    static func preflight(_ ds: ParsedDataset, currentAppVersion: String) throws {
        let req = ds.manifest.compatibleAppVersion
        if !VersionCompare.satisfies(constraint: req, version: currentAppVersion) {
            throw SampleDataError.incompatibleAppVersion(required: req, current: currentAppVersion)
        }
    }
}

// MARK: - Trivial semver constraint check (>=N.N.N)

enum VersionCompare {
    static func satisfies(constraint: String, version: String) -> Bool {
        guard constraint.hasPrefix(">=") else { return true }  // unknown ⇒ permissive
        let req = String(constraint.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        return compare(version, req) >= 0
    }

    static func compare(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}
