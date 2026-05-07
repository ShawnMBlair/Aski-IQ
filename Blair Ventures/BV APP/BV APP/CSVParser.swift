// CSVParser.swift
// Aski IQ – RFC 4180-compliant CSV parser

import Foundation

enum CSVParser {

    // MARK: - Public API

    /// Parse raw Data into headers + rows.
    /// Returns (headers, rows) where each row is a [String] of values aligned to headers.
    static func parse(_ data: Data) throws -> (headers: [String], rows: [[String]]) {
        guard let text = String(data: data, encoding: .utf8) ??
                         String(data: data, encoding: .windowsCP1252) ??
                         String(data: data, encoding: .isoLatin1) else {
            throw ImportFileError.invalidEncoding
        }
        var lines = parseFields(text)
        guard !lines.isEmpty else { throw ImportFileError.emptyFile }

        // Strip BOM if present
        if var first = lines.first?.first, first.hasPrefix("\u{FEFF}") {
            first.removeFirst()
            lines[0][0] = first
        }

        let headers = lines.removeFirst().map { $0.trimmingCharacters(in: .whitespaces) }
        guard !headers.isEmpty else { throw ImportFileError.emptyFile }

        // Pad / trim each row to header count
        let normalised = lines.compactMap { row -> [String]? in
            guard !row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
            var r = row
            while r.count < headers.count { r.append("") }
            return Array(r.prefix(headers.count))
        }
        return (headers, normalised)
    }

    /// Convenience: build an array of [header: value] dicts.
    static func parseDicts(_ data: Data) throws -> [[String: String]] {
        let (headers, rows) = try parse(data)
        return rows.map { row in
            Dictionary(uniqueKeysWithValues: zip(headers, row))
        }
    }

    // MARK: - RFC 4180 Field Parser

    private static func parseFields(_ text: String) -> [[String]] {
        var result: [[String]] = []
        var currentRow: [String] = []
        var field = ""
        var inQuotes = false
        var i = text.startIndex

        func finishRow() {
            currentRow.append(field)
            field = ""
            if !currentRow.allSatisfy({ $0.isEmpty }) {
                result.append(currentRow)
            }
            currentRow = []
        }

        while i < text.endIndex {
            let c = text[i]
            let next = text.index(after: i)

            if inQuotes {
                if c == "\"" {
                    if next < text.endIndex && text[next] == "\"" {
                        // Escaped quote ""
                        field.append("\"")
                        i = text.index(after: next)
                        continue
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                case ",":
                    currentRow.append(field)
                    field = ""
                case "\r":
                    if next < text.endIndex && text[next] == "\n" {
                        i = next
                    }
                    finishRow()
                    i = text.index(after: i)
                    continue
                case "\n":
                    finishRow()
                    i = next
                    continue
                default:
                    field.append(c)
                }
            }
            i = text.index(after: i)
        }

        // Trailing content (no final newline)
        currentRow.append(field)
        if !currentRow.allSatisfy({ $0.isEmpty }) {
            result.append(currentRow)
        }
        return result
    }
}

// MARK: - Import File Errors

enum ImportFileError: LocalizedError {
    case invalidEncoding
    case emptyFile
    case invalidFileType
    case missingRequiredColumn(String)

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            return "File encoding not recognised. Save your spreadsheet as UTF-8 CSV and try again."
        case .emptyFile:
            return "The file appears to be empty. Check that it contains at least a header row and one data row."
        case .invalidFileType:
            return "Only .csv files are supported. Export your spreadsheet as CSV first."
        case .missingRequiredColumn(let col):
            return "Required column '\(col)' is missing from the file."
        }
    }
}
