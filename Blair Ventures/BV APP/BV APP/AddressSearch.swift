// AddressSearch.swift
// BV APP – MapKit address autocomplete (reusable)

import SwiftUI
import MapKit
import Combine

// MARK: - Parsed Address

struct ParsedAddress {
    var street:     String = ""
    var city:       String = ""
    var province:   String = ""   // administrativeArea (AB, ON, etc.)
    var postalCode: String = ""
    var country:    String = ""

    /// Single-line display string
    var oneLiner: String {
        [street, city, province, postalCode]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

// MARK: - Search Completer (ViewModel)

final class AddressSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {

    @Published var suggestions: [MKLocalSearchCompletion] = []
    @Published var isBusy = false

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate   = self
        completer.resultTypes = .address
    }

    func update(query: String) {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            suggestions = []
            return
        }
        isBusy = true
        completer.queryFragment = query
    }

    // MKLocalSearchCompleterDelegate
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        isBusy       = false
        suggestions  = completer.results
    }
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        isBusy      = false
        suggestions = []
    }
}

// MARK: - Address Search Sheet
// Present with .sheet(isPresented:) { AddressSearchSheet(…) }
// The onSelect callback delivers fully parsed address components.

struct AddressSearchSheet: View {
    let title:       String
    var initialText: String = ""
    let onSelect:    (ParsedAddress) -> Void

    @StateObject private var completer = AddressSearchCompleter()
    @Environment(\.dismiss) var dismiss

    @State private var query     = ""
    @State private var resolving = false

    var body: some View {
        NavigationStack {
            List {
                if completer.isBusy || resolving {
                    HStack {
                        Spacer()
                        ProgressView().padding(.vertical, 8)
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                }

                ForEach(completer.suggestions.prefix(8), id: \.self) { suggestion in
                    Button {
                        resolve(suggestion)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(suggestion.title)
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundColor(.primary)
                }

                if !query.isEmpty,
                   completer.suggestions.isEmpty,
                   !completer.isBusy {
                    Text("No results — try a different search.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Street, city, or postal code"
            )
            .onChange(of: query) { _, new in completer.update(query: new) }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if !initialText.isEmpty {
                    query = initialText
                    completer.update(query: initialText)
                }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - Resolve selection → full placemark

    private func resolve(_ suggestion: MKLocalSearchCompletion) {
        resolving = true
        let request = MKLocalSearch.Request(completion: suggestion)
        MKLocalSearch(request: request).start { response, _ in
            DispatchQueue.main.async {
                resolving = false
                guard let placemark = response?.mapItems.first?.placemark else {
                    // Fallback to raw title text
                    onSelect(ParsedAddress(street: suggestion.title))
                    dismiss()
                    return
                }
                let streetParts = [placemark.subThoroughfare, placemark.thoroughfare]
                    .compactMap { $0 }
                let street = streetParts.isEmpty
                    ? suggestion.title
                    : streetParts.joined(separator: " ")
                let parsed = ParsedAddress(
                    street:     street,
                    city:       placemark.locality            ?? "",
                    province:   placemark.administrativeArea  ?? "",
                    postalCode: placemark.postalCode          ?? "",
                    country:    placemark.country             ?? ""
                )
                onSelect(parsed)
                dismiss()
            }
        }
    }
}

// MARK: - Address Row (reusable Form row)
// Shows current value + search icon; opens AddressSearchSheet on tap.

struct AddressSearchRow: View {
    let label:     String
    @Binding var street:     String
    @Binding var city:       String
    @Binding var province:   String
    @Binding var postalCode: String

    @State private var showSheet = false

    private var displayText: String {
        let parts = [street, city, province, postalCode].filter { !$0.isEmpty }
        return parts.isEmpty ? "Search address…" : parts.joined(separator: ", ")
    }

    var body: some View {
        Button {
            showSheet = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.blue)
                    .font(.subheadline)
                Text(displayText)
                    .font(.subheadline)
                    .foregroundColor(street.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .foregroundColor(.primary)
        .sheet(isPresented: $showSheet) {
            AddressSearchSheet(title: label, initialText: street) { parsed in
                street     = parsed.street
                city       = parsed.city.isEmpty    ? city       : parsed.city
                province   = parsed.province.isEmpty ? province   : parsed.province
                postalCode = parsed.postalCode.isEmpty ? postalCode : parsed.postalCode
            }
        }
    }
}
