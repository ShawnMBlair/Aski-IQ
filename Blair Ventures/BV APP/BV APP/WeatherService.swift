// WeatherService.swift
// BV APP – Live weather via Open-Meteo (no API key required) + CoreLocation

import SwiftUI
import CoreLocation
import Combine

// MARK: - Weather Data Model

struct WeatherData: Equatable {
    var temperature:         Double    // °C
    var apparentTemperature: Double    // °C – feels like
    var humidity:            Int       // %
    var windSpeed:           Double    // km/h
    var windDirection:       Int       // degrees 0-360
    var precipitation:       Double    // mm (last hour)
    var conditionCode:       Int       // WMO weather code
    var fetchedAt:           Date
    var locationName:        String?

    // MARK: Derived strings

    var tempString:       String { String(format: "%.0f°C", temperature) }
    var feelsLikeString:  String { String(format: "%.0f°C", apparentTemperature) }
    var windString:       String { String(format: "%.0f km/h \(windCardinal)", windSpeed) }
    var humidityString:   String { "\(humidity)%" }
    var precipString:     String { String(format: "%.1f mm", precipitation) }
    var conditionText:    String { WMOCode.description(for: conditionCode) }
    var conditionIcon:    String { WMOCode.sfSymbol(for: conditionCode) }

    var windCardinal: String {
        let dirs = ["N","NE","E","SE","S","SW","W","NW","N"]
        return dirs[Int((Double(windDirection) + 22.5) / 45.0) % 8]
    }

    /// One-line summary suitable for a form field
    var summaryForForm: String {
        "\(conditionText), \(tempString) (feels \(feelsLikeString)), Wind \(windString), Humidity \(humidityString)"
    }
}

// MARK: - WMO Weather Code Lookup

enum WMOCode {
    static func description(for code: Int) -> String {
        switch code {
        case 0:        return "Clear Sky"
        case 1:        return "Mainly Clear"
        case 2:        return "Partly Cloudy"
        case 3:        return "Overcast"
        case 45, 48:   return "Foggy"
        case 51:       return "Light Drizzle"
        case 53:       return "Moderate Drizzle"
        case 55:       return "Dense Drizzle"
        case 61:       return "Light Rain"
        case 63:       return "Moderate Rain"
        case 65:       return "Heavy Rain"
        case 71:       return "Light Snow"
        case 73:       return "Moderate Snow"
        case 75:       return "Heavy Snow"
        case 77:       return "Snow Grains"
        case 80:       return "Light Showers"
        case 81:       return "Moderate Showers"
        case 82:       return "Violent Showers"
        case 85, 86:   return "Snow Showers"
        case 95:       return "Thunderstorm"
        case 96, 99:   return "Thunderstorm w/ Hail"
        default:       return "Unknown"
        }
    }

    static func sfSymbol(for code: Int) -> String {
        switch code {
        case 0:        return "sun.max.fill"
        case 1:        return "sun.haze.fill"
        case 2:        return "cloud.sun.fill"
        case 3:        return "cloud.fill"
        case 45, 48:   return "cloud.fog.fill"
        case 51...55:  return "cloud.drizzle.fill"
        case 61...65:  return "cloud.rain.fill"
        case 71...77:  return "cloud.snow.fill"
        case 80...82:  return "cloud.heavyrain.fill"
        case 85, 86:   return "cloud.snow.fill"
        case 95...99:  return "cloud.bolt.rain.fill"
        default:       return "cloud.fill"
        }
    }

    static func color(for code: Int) -> Color {
        switch code {
        case 0, 1:     return .yellow
        case 2, 3:     return .gray
        case 45, 48:   return Color(white: 0.6)
        case 51...55:  return .teal
        case 61...65:  return .blue
        case 71...77:  return .cyan
        case 80...82:  return .blue
        case 95...99:  return .purple
        default:       return .gray
        }
    }
}

// MARK: - Open-Meteo Response

private struct OpenMeteoResponse: Decodable {
    struct Current: Decodable {
        let temperature_2m:         Double
        let apparent_temperature:   Double
        let relative_humidity_2m:   Int
        let precipitation:          Double
        let weather_code:           Int
        let wind_speed_10m:         Double
        let wind_direction_10m:     Int
    }
    let current: Current
}

// MARK: - Weather Service

@MainActor
final class WeatherService: NSObject, ObservableObject, CLLocationManagerDelegate {

    static let shared = WeatherService()

    @Published var weather:   WeatherData? = nil
    @Published var isLoading: Bool = false
    @Published var error:     String? = nil

    private let locationManager = CLLocationManager()
    private var lastFetch: Date? = nil
    private let cacheMinutes: TimeInterval = 10 * 60   // re-fetch every 10 min

    private override init() {
        super.init()
        locationManager.delegate         = self
        locationManager.desiredAccuracy  = kCLLocationAccuracyKilometer
    }

    // MARK: - Public API

    func fetchIfNeeded() {
        // Skip if data is fresh
        if let last = lastFetch, Date().timeIntervalSince(last) < cacheMinutes,
           weather != nil { return }

        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.requestLocation()
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        default:
            error = "Location access denied — weather unavailable."
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if manager.authorizationStatus == .authorizedWhenInUse ||
               manager.authorizationStatus == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            await fetchWeather(lat: loc.coordinate.latitude,
                               lon: loc.coordinate.longitude,
                               location: loc)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        Task { @MainActor in
            self.error = "Location error: \(error.localizedDescription)"
            self.isLoading = false
        }
    }

    // MARK: - Fetch Weather

    private func fetchWeather(lat: Double, lon: Double, location: CLLocation) async {
        isLoading = true
        error     = nil

        // Reverse-geocode for city name (best effort)
        let cityName = await reverseGeocode(location)

        let urlString = "https://api.open-meteo.com/v1/forecast" +
            "?latitude=\(lat)&longitude=\(lon)" +
            "&current=temperature_2m,relative_humidity_2m,apparent_temperature," +
            "precipitation,weather_code,wind_speed_10m,wind_direction_10m" +
            "&temperature_unit=celsius&wind_speed_unit=kmh&timezone=auto"

        guard let url = URL(string: urlString) else {
            isLoading = false; return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded   = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            let c         = decoded.current

            weather = WeatherData(
                temperature:         c.temperature_2m,
                apparentTemperature: c.apparent_temperature,
                humidity:            c.relative_humidity_2m,
                windSpeed:           c.wind_speed_10m,
                windDirection:       c.wind_direction_10m,
                precipitation:       c.precipitation,
                conditionCode:       c.weather_code,
                fetchedAt:           Date(),
                locationName:        cityName
            )
            lastFetch = Date()
        } catch {
            self.error = "Weather unavailable."
        }
        isLoading = false
    }

    private func reverseGeocode(_ location: CLLocation) async -> String? {
        await withCheckedContinuation { cont in
            CLGeocoder().reverseGeocodeLocation(location) { placemarks, _ in
                let city = placemarks?.first?.locality
                cont.resume(returning: city)
            }
        }
    }
}

// MARK: - Weather Card (Dashboard widget)

struct WeatherCard: View {
    @ObservedObject private var service = WeatherService.shared

    var body: some View {
        Group {
            if let w = service.weather {
                loadedCard(w)
            } else if service.isLoading {
                loadingCard
            } else {
                unavailableCard
            }
        }
        .onAppear { service.fetchIfNeeded() }
    }

    // MARK: Loaded state

    private func loadedCard(_ w: WeatherData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Top row: icon + temp + condition + location
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: w.conditionIcon)
                    .font(.system(size: 38))
                    .foregroundColor(WMOCode.color(for: w.conditionCode))
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 3) {
                    Text(w.tempString)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text(w.conditionText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if let city = w.locationName {
                    VStack(alignment: .trailing, spacing: 2) {
                        Image(systemName: "location.fill")
                            .font(.caption2)
                            .foregroundColor(.blue)
                        Text(city)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Divider()

            // Detail row
            HStack(spacing: 0) {
                WeatherStat(icon: "thermometer.medium", label: "Feels like", value: w.feelsLikeString, color: .orange)
                Divider().frame(height: 36)
                WeatherStat(icon: "wind", label: "Wind", value: w.windString, color: .blue)
                Divider().frame(height: 36)
                WeatherStat(icon: "humidity.fill", label: "Humidity", value: w.humidityString, color: .cyan)
                Divider().frame(height: 36)
                WeatherStat(icon: "cloud.rain.fill", label: "Precip", value: w.precipString, color: .indigo)
            }

            // Timestamp + refresh
            HStack {
                Text("Updated \(w.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    WeatherService.shared.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .padding(.horizontal)
    }

    // MARK: Loading state

    private var loadingCard: some View {
        HStack(spacing: 14) {
            ProgressView()
            Text("Fetching weather…")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .padding(.horizontal)
    }

    // MARK: Unavailable state

    private var unavailableCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "cloud.slash.fill")
                .foregroundColor(.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Weather unavailable")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                if let err = service.error {
                    Text(err)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Button {
                WeatherService.shared.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundColor(.blue)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .padding(.horizontal)
    }
}

// MARK: - Weather Stat Tile

private struct WeatherStat: View {
    let icon:  String
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.subheadline)
            Text(value)
                .font(.caption)
                .bold()
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Refresh helper (public, non-async)

extension WeatherService {
    func refresh() {
        lastFetch = nil
        weather   = nil
        fetchIfNeeded()
    }
}
