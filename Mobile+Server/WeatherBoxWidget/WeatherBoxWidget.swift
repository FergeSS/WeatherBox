import AppIntents
import SwiftUI
import WidgetKit

private enum WeatherBoxWidgetConfig {
    static let defaultServerAddress = "http://5.129.195.241:18080"
    static let legacyDeviceAddress = "192.168.4.1"
    static let vpnHint = "Выключите VPN"

    static func resolvedAddress(from rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || isLegacyAddress(trimmed) {
            return defaultServerAddress
        }
        return trimmed
    }

    static func displayAddress(from rawValue: String) -> String {
        let resolved = resolvedAddress(from: rawValue)
        if let host = URL(string: resolved)?.host {
            return host
        }
        return resolved
    }

    private static func isLegacyAddress(_ value: String) -> Bool {
        value == legacyDeviceAddress
            || value == "http://\(legacyDeviceAddress)"
            || value == "https://\(legacyDeviceAddress)"
    }
}

struct WeatherBoxWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "WeatherBox"
    static var description = IntentDescription("Показывает температуру, влажность и состояние вашего ESP8266.")

    @Parameter(title: "Адрес сервера", default: "http://5.129.195.241:18080")
    var deviceAddress: String

    @Parameter(title: "Заголовок", default: "WeatherBox")
    var title: String
}

struct WeatherBoxWidgetEntry: TimelineEntry {
    let date: Date
    let configuration: WeatherBoxWidgetConfigurationIntent
    let state: WeatherBoxWidgetState
}

enum WeatherBoxWidgetState {
    case loaded(WeatherBoxWidgetSnapshot)
    case sensorUnavailable(WeatherBoxWidgetStatus)
    case offline(String)
}

struct WeatherBoxWidgetStatus: Decodable {
    let mode: String
    let connected: Bool
    let ip: String
}

struct WeatherBoxWidgetSensor: Decodable {
    let temperature: Double
    let humidity: Double
    let unitTemperature: String
    let unitHumidity: String

    enum CodingKeys: String, CodingKey {
        case temperature
        case humidity
        case unitTemperature = "unit_temperature"
        case unitHumidity = "unit_humidity"
    }
}

struct WeatherBoxWidgetSnapshot {
    let status: WeatherBoxWidgetStatus
    let sensor: WeatherBoxWidgetSensor
}

struct WeatherBoxWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> WeatherBoxWidgetEntry {
        WeatherBoxWidgetEntry(
            date: .now,
            configuration: WeatherBoxWidgetConfigurationIntent(),
            state: .loaded(
                WeatherBoxWidgetSnapshot(
                    status: WeatherBoxWidgetStatus(mode: "station", connected: true, ip: "10.0.0.77"),
                    sensor: WeatherBoxWidgetSensor(temperature: 23.4, humidity: 54.0, unitTemperature: "C", unitHumidity: "%")
                )
            )
        )
    }

    func snapshot(for configuration: WeatherBoxWidgetConfigurationIntent, in context: Context) async -> WeatherBoxWidgetEntry {
        await makeEntry(for: configuration)
    }

    func timeline(for configuration: WeatherBoxWidgetConfigurationIntent, in context: Context) async -> Timeline<WeatherBoxWidgetEntry> {
        let entry = await makeEntry(for: configuration)
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now.addingTimeInterval(900)
        return Timeline(entries: [entry], policy: .after(nextRefresh))
    }

    private func makeEntry(for configuration: WeatherBoxWidgetConfigurationIntent) async -> WeatherBoxWidgetEntry {
        let state = await WeatherBoxWidgetClient().load(address: configuration.deviceAddress)
        return WeatherBoxWidgetEntry(date: .now, configuration: configuration, state: state)
    }
}

struct WeatherBoxWidgetClient {
    private let decoder = JSONDecoder()

    func load(address: String) async -> WeatherBoxWidgetState {
        let resolvedAddress = WeatherBoxWidgetConfig.resolvedAddress(from: address)

        do {
            let status: WeatherBoxWidgetStatus = try await fetch(path: "/status", address: resolvedAddress)

            do {
                let sensor: WeatherBoxWidgetSensor = try await fetch(path: "/sensor", address: resolvedAddress)
                return .loaded(WeatherBoxWidgetSnapshot(status: status, sensor: sensor))
            } catch {
                return .sensorUnavailable(status)
            }
        } catch {
            return .offline("Нет связи с сервером")
        }
    }

    private func fetch<Response: Decodable>(path: String, address: String) async throws -> Response {
        guard let url = normalizedURL(address: address, path: path) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200 ..< 300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try decoder.decode(Response.self, from: data)
    }

    private func normalizedURL(address: String, path: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let candidate = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: candidate) else {
            return nil
        }

        components.path = path
        return components.url
    }
}

struct WeatherBoxWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.showsWidgetContainerBackground) private var showsWidgetContainerBackground
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode

    let entry: WeatherBoxWidgetEntry

    var body: some View {
        Group {
            switch entry.state {
            case let .loaded(snapshot):
                loadedView(snapshot)
            case let .sensorUnavailable(status):
                sensorUnavailableView(status)
            case let .offline(message):
                offlineView(message)
            }
        }
        .widgetURL(URL(string: "weatherbox://open"))
        .containerBackground(for: .widget) {
            background
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.16, green: 0.55, blue: 0.95),
                Color(red: 0.48, green: 0.78, blue: 1.0)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var usesFullColorBackground: Bool {
        showsWidgetContainerBackground && widgetRenderingMode == .fullColor
    }

    private var primaryForeground: Color {
        usesFullColorBackground ? .white : .primary
    }

    private var secondaryForeground: Color {
        usesFullColorBackground ? Color.white.opacity(0.85) : .secondary
    }

    private var badgeBackground: Color {
        usesFullColorBackground ? Color.white.opacity(0.16) : Color.primary.opacity(0.12)
    }

    private var indicatorFill: Color {
        usesFullColorBackground ? Color.white.opacity(0.9) : Color.primary.opacity(0.9)
    }

    private var vpnHintBackground: Color {
        usesFullColorBackground ? Color.white.opacity(0.14) : Color.orange.opacity(0.15)
    }

    private var vpnHintForeground: Color {
        usesFullColorBackground ? .white : .orange
    }

    private var resolvedAddressLabel: String {
        WeatherBoxWidgetConfig.displayAddress(from: entry.configuration.deviceAddress)
    }

    @ViewBuilder
    private func loadedView(_ snapshot: WeatherBoxWidgetSnapshot) -> some View {
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 10) {
                widgetHeader(title: entry.configuration.title)
                Text(temperatureText(snapshot.sensor))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(primaryForeground)
                    .widgetAccentable()
                Text("Влажность \(humidityText(snapshot.sensor, fractionLength: 0))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(secondaryForeground)
                Spacer()
                footer(status: snapshot.status)
            }
            .padding(16)

        case .systemMedium:
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    widgetHeader(title: entry.configuration.title)
                    metric(title: "Температура", value: temperatureText(snapshot.sensor))
                    metric(title: "Влажность", value: humidityText(snapshot.sensor, fractionLength: 0))
                    Spacer()
                    footer(status: snapshot.status)
                }

                Spacer()

                VStack(spacing: 10) {
                    Image(systemName: "humidifier.and.droplets.fill")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(primaryForeground)
                        .widgetAccentable()
                    Text(snapshot.status.mode.capitalized)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(primaryForeground)
                        .widgetAccentable()
                    Text(snapshot.status.ip)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(secondaryForeground)
                }
                .frame(maxWidth: 96)
            }
            .padding(18)

        case .systemLarge:
            VStack(alignment: .leading, spacing: 16) {
                widgetHeader(title: entry.configuration.title)

                Text(temperatureText(snapshot.sensor))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(primaryForeground)
                    .widgetAccentable()

                HStack(spacing: 12) {
                    metric(title: "Влажность", value: humidityText(snapshot.sensor, fractionLength: 0))
                    metric(title: "Режим", value: snapshot.status.mode.capitalized)
                }

                HStack(spacing: 12) {
                    metric(title: "IP устройства", value: snapshot.status.ip)
                    metric(title: "Backend", value: resolvedAddressLabel)
                }

                Spacer()
                footer(status: snapshot.status)
            }
            .padding(18)

        case .accessoryInline:
            Text("\(compactTemperatureText(snapshot.sensor)) • \(humidityText(snapshot.sensor, fractionLength: 0))")

        case .accessoryCircular:
            VStack(spacing: 2) {
                Image(systemName: "thermometer.medium")
                    .font(.caption.weight(.bold))
                Text(compactTemperatureText(snapshot.sensor))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundStyle(primaryForeground)
            .widgetAccentable()

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.configuration.title)
                        .font(.caption2.weight(.bold))
                    Spacer()
                    Text(snapshot.status.connected ? "Online" : "AP")
                        .font(.caption2.weight(.bold))
                }
                Text(temperatureText(snapshot.sensor))
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("Влажность \(humidityText(snapshot.sensor, fractionLength: 0))")
                    .font(.caption)
                    .foregroundStyle(secondaryForeground)
            }
            .foregroundStyle(primaryForeground)

        default:
            loadedViewFallback(snapshot)
        }
    }

    @ViewBuilder
    private func loadedViewFallback(_ snapshot: WeatherBoxWidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            widgetHeader(title: entry.configuration.title)
            Text(temperatureText(snapshot.sensor))
                .font(.title2.weight(.bold))
                .foregroundStyle(primaryForeground)
            Text("Влажность \(humidityText(snapshot.sensor, fractionLength: 0))")
                .font(.subheadline)
                .foregroundStyle(secondaryForeground)
            Spacer()
            footer(status: snapshot.status)
        }
        .padding(16)
    }

    @ViewBuilder
    private func sensorUnavailableView(_ status: WeatherBoxWidgetStatus) -> some View {
        switch family {
        case .accessoryInline:
            Text("Датчик недоступен")

        case .accessoryCircular:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(primaryForeground)

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.configuration.title)
                    .font(.caption2.weight(.bold))
                Text("Датчик недоступен")
                    .font(.headline.weight(.bold))
                Text(status.connected ? "ESP8266 на связи" : "Нет свежего сигнала")
                    .font(.caption)
                    .foregroundStyle(secondaryForeground)
            }
            .foregroundStyle(primaryForeground)

        default:
            VStack(alignment: .leading, spacing: 12) {
                widgetHeader(title: entry.configuration.title)
                Spacer()
                Label("Датчик временно недоступен", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(primaryForeground)
                Text("ESP8266 на связи, но DHT11 сейчас не ответил.")
                    .font(.caption)
                    .foregroundStyle(secondaryForeground)
                Spacer()
                footer(status: status)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func offlineView(_ message: String) -> some View {
        switch family {
        case .accessoryInline:
            Text("WeatherBox: \(WeatherBoxWidgetConfig.vpnHint)")

        case .accessoryCircular:
            VStack(spacing: 2) {
                Image(systemName: "network.slash")
                    .font(.caption.weight(.bold))
                Text("VPN")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(primaryForeground)

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.configuration.title)
                    .font(.caption2.weight(.bold))
                Text("Нет связи с сервером")
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(WeatherBoxWidgetConfig.vpnHint)
                    .font(.caption)
                    .foregroundStyle(secondaryForeground)
            }
            .foregroundStyle(primaryForeground)

        default:
            VStack(alignment: .leading, spacing: 12) {
                widgetHeader(title: entry.configuration.title)
                Spacer()
                Image(systemName: "wifi.slash")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(primaryForeground)
                Text("Offline")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(primaryForeground)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(secondaryForeground)
                vpnHintPill
                Spacer()
                Text(resolvedAddressLabel)
                    .font(.caption2)
                    .foregroundStyle(secondaryForeground)
            }
            .padding(16)
        }
    }

    private var vpnHintPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "network.slash")
            Text(WeatherBoxWidgetConfig.vpnHint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(vpnHintForeground)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(vpnHintBackground, in: Capsule())
    }

    private func widgetHeader(title: String) -> some View {
        HStack {
            Label(title, systemImage: "sensor.tag.radiowaves.forward")
                .font(.caption.weight(.bold))
                .lineLimit(1)
            Spacer()
            Circle()
                .fill(indicatorFill)
                .frame(width: 8, height: 8)
        }
        .foregroundStyle(primaryForeground)
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(secondaryForeground)
            Text(value)
                .font(.title3.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .foregroundStyle(primaryForeground)
        }
    }

    private func footer(status: WeatherBoxWidgetStatus) -> some View {
        HStack {
            Text(status.connected ? "Station" : "AP")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(badgeBackground, in: Capsule())
            Spacer()
            Text(status.ip)
                .font(.caption2)
                .foregroundStyle(secondaryForeground)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(primaryForeground)
    }

    private func temperatureText(_ sensor: WeatherBoxWidgetSensor) -> String {
        "\(sensor.temperature.formatted(.number.precision(.fractionLength(1))))°\(sensor.unitTemperature)"
    }

    private func compactTemperatureText(_ sensor: WeatherBoxWidgetSensor) -> String {
        "\(sensor.temperature.formatted(.number.precision(.fractionLength(0))))°"
    }

    private func humidityText(_ sensor: WeatherBoxWidgetSensor, fractionLength: Int) -> String {
        "\(sensor.humidity.formatted(.number.precision(.fractionLength(fractionLength))))\(sensor.unitHumidity)"
    }
}

struct WeatherBoxStatusWidget: Widget {
    let kind = "WeatherBoxStatusWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: WeatherBoxWidgetConfigurationIntent.self,
            provider: WeatherBoxWidgetProvider()
        ) { entry in
            WeatherBoxWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("WeatherBox Status")
        .description("Показывает температуру, влажность и состояние ESP8266 через удаленный backend.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .accessoryInline,
            .accessoryCircular,
            .accessoryRectangular,
        ])
        .containerBackgroundRemovable(false)
        .promptsForUserConfiguration()
    }
}

@main
struct WeatherBoxWidgets: WidgetBundle {
    var body: some Widget {
        WeatherBoxStatusWidget()
    }
}

#Preview(as: .systemSmall, using: WeatherBoxWidgetConfigurationIntent(), widget: {
    WeatherBoxStatusWidget()
}, timelineProvider: {
    WeatherBoxWidgetProvider()
})

#Preview(as: .systemMedium, using: WeatherBoxWidgetConfigurationIntent(), widget: {
    WeatherBoxStatusWidget()
}, timelineProvider: {
    WeatherBoxWidgetProvider()
})

#Preview(as: .systemLarge, using: WeatherBoxWidgetConfigurationIntent(), widget: {
    WeatherBoxStatusWidget()
}, timelineProvider: {
    WeatherBoxWidgetProvider()
})

#Preview(as: .accessoryInline, using: WeatherBoxWidgetConfigurationIntent(), widget: {
    WeatherBoxStatusWidget()
}, timelineProvider: {
    WeatherBoxWidgetProvider()
})

#Preview(as: .accessoryCircular, using: WeatherBoxWidgetConfigurationIntent(), widget: {
    WeatherBoxStatusWidget()
}, timelineProvider: {
    WeatherBoxWidgetProvider()
})

#Preview(as: .accessoryRectangular, using: WeatherBoxWidgetConfigurationIntent(), widget: {
    WeatherBoxStatusWidget()
}, timelineProvider: {
    WeatherBoxWidgetProvider()
})
