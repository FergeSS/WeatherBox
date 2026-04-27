import Foundation

struct DeviceStatus: Decodable, Equatable {
    let mode: String
    let connected: Bool
    let ip: String
    let apSSID: String
    let apPassword: String
    let storedSSID: String
    let currentSSID: String
    let lastSeen: String?
    let stale: Bool?

    enum CodingKeys: String, CodingKey {
        case mode
        case connected
        case ip
        case apSSID = "ap_ssid"
        case apPassword = "ap_password"
        case storedSSID = "stored_ssid"
        case currentSSID = "current_ssid"
        case lastSeen = "last_seen"
        case stale
    }
}

struct SensorReading: Decodable, Equatable {
    let temperature: Double
    let humidity: Double
    let atmosphericPressure: Double?
    let unitTemperature: String
    let unitHumidity: String
    let unitAtmosphericPressure: String
    let lastSeen: String?

    enum CodingKeys: String, CodingKey {
        case temperature
        case humidity
        case atmosphericPressure = "atmospheric_pressure"
        case unitTemperature = "unit_temperature"
        case unitHumidity = "unit_humidity"
        case unitAtmosphericPressure = "unit_atmospheric_pressure"
        case lastSeen = "last_seen"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        temperature = try container.decode(Double.self, forKey: .temperature)
        humidity = try container.decode(Double.self, forKey: .humidity)
        atmosphericPressure = try container.decodeIfPresent(Double.self, forKey: .atmosphericPressure)
        unitTemperature = try container.decodeIfPresent(String.self, forKey: .unitTemperature) ?? "C"
        unitHumidity = try container.decodeIfPresent(String.self, forKey: .unitHumidity) ?? "%"
        unitAtmosphericPressure = try container.decodeIfPresent(String.self, forKey: .unitAtmosphericPressure) ?? "hPa"
        lastSeen = try container.decodeIfPresent(String.self, forKey: .lastSeen)
    }
}

struct SensorHistoryEntry: Decodable, Equatable {
    let temperature: Double
    let humidity: Double
    let atmosphericPressure: Double?
    let unitTemperature: String
    let unitHumidity: String
    let unitAtmosphericPressure: String
    let recordedAt: String

    enum CodingKeys: String, CodingKey {
        case temperature
        case humidity
        case atmosphericPressure = "atmospheric_pressure"
        case unitTemperature = "unit_temperature"
        case unitHumidity = "unit_humidity"
        case unitAtmosphericPressure = "unit_atmospheric_pressure"
        case recordedAt = "recorded_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        temperature = try container.decode(Double.self, forKey: .temperature)
        humidity = try container.decode(Double.self, forKey: .humidity)
        atmosphericPressure = try container.decodeIfPresent(Double.self, forKey: .atmosphericPressure)
        unitTemperature = try container.decodeIfPresent(String.self, forKey: .unitTemperature) ?? "C"
        unitHumidity = try container.decodeIfPresent(String.self, forKey: .unitHumidity) ?? "%"
        unitAtmosphericPressure = try container.decodeIfPresent(String.self, forKey: .unitAtmosphericPressure) ?? "hPa"
        recordedAt = try container.decode(String.self, forKey: .recordedAt)
    }
}

struct SensorHistoryResponse: Decodable, Equatable {
    let ok: Bool?
    let deviceId: String?
    let history: [SensorHistoryEntry]
    let count: Int?
    let retentionHours: Int?

    enum CodingKeys: String, CodingKey {
        case ok
        case deviceId = "device_id"
        case history
        case count
        case retentionHours = "retention_hours"
    }
}

struct APIResponse: Decodable, Equatable {
    let ok: Bool?
    let message: String?
    let error: String?
    let ssid: String?
}

enum WeatherBoxError: LocalizedError, Equatable {
    case invalidAddress
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "Некорректный адрес сервера."
        case .invalidResponse:
            return "Сервер вернул неполный ответ."
        case let .server(message):
            return message
        }
    }
}

struct WeatherBoxAPI {
    static let defaultBaseAddress = "http://5.129.195.241:18080"

    private let decoder: JSONDecoder = JSONDecoder()
    private let baseAddress: String

    init(baseAddress: String = Self.defaultBaseAddress) {
        self.baseAddress = baseAddress
    }

    func fetchStatus() async throws -> DeviceStatus {
        try await sendRequest(path: "/status")
    }

    func fetchSensor() async throws -> SensorReading {
        try await sendRequest(path: "/sensor")
    }

    func fetchHistory() async throws -> SensorHistoryResponse {
        try await sendRequest(path: "/history")
    }

    private func sendRequest<Response: Decodable>(
        path: String
    ) async throws -> Response {
        guard let url = normalizedURL(baseAddress: baseAddress, path: path) else {
            throw WeatherBoxError.invalidAddress
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 6

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WeatherBoxError.invalidResponse
        }

        if (200 ..< 300).contains(httpResponse.statusCode) {
            do {
                return try decoder.decode(Response.self, from: data)
            } catch {
                throw WeatherBoxError.invalidResponse
            }
        }

        if let apiError = try? decoder.decode(APIResponse.self, from: data), let message = apiError.error ?? apiError.message {
            throw WeatherBoxError.server(message.replacingOccurrences(of: "_", with: " "))
        }

        throw WeatherBoxError.server("Ошибка сервера: \(httpResponse.statusCode)")
    }

    private func normalizedURL(baseAddress: String, path: String) -> URL? {
        let trimmed = baseAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let candidate = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: candidate) else {
            return nil
        }

        let sanitizedPath = path.hasPrefix("/") ? path : "/\(path)"
        components.path = sanitizedPath
        return components.url
    }
}
