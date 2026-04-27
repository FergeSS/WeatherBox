//
//  WeatherBoxTests.swift
//  WeatherBoxTests
//
//  Created by FergeS on 28.03.2026.
//

import Foundation
import Testing
@testable import WeatherBox

struct WeatherBoxTests {
    @Test func decodesStatusPayload() throws {
        let data = Data("""
        {
            "mode": "station",
            "connected": true,
            "ip": "192.168.1.20",
            "ap_ssid": "ESP8266_DHT11_1234",
            "ap_password": "12345678",
            "stored_ssid": "HomeWiFi",
            "current_ssid": "HomeWiFi"
        }
        """.utf8)

        let status = try JSONDecoder().decode(DeviceStatus.self, from: data)

        #expect(status.mode == "station")
        #expect(status.connected)
        #expect(status.apSSID == "ESP8266_DHT11_1234")
        #expect(status.currentSSID == "HomeWiFi")
    }

    @Test func decodesSensorPayloadWithOptionalPressure() throws {
        let data = Data("""
        {
            "temperature": 24.7,
            "humidity": 57.3,
            "atmospheric_pressure": 1007.2,
            "unit_temperature": "C",
            "unit_humidity": "%",
            "unit_atmospheric_pressure": "hPa",
            "last_seen": "2026-04-24T17:15:55.848998Z"
        }
        """.utf8)

        let sensor = try JSONDecoder().decode(SensorReading.self, from: data)

        #expect(sensor.temperature == 24.7)
        #expect(sensor.humidity == 57.3)
        #expect(sensor.atmosphericPressure == 1007.2)
        #expect(sensor.unitAtmosphericPressure == "hPa")
    }

    @Test func decodesSensorPayloadWithoutPressure() throws {
        let data = Data("""
        {
            "temperature": 24.7,
            "humidity": 57.3,
            "unit_temperature": "C",
            "unit_humidity": "%"
        }
        """.utf8)

        let sensor = try JSONDecoder().decode(SensorReading.self, from: data)

        #expect(sensor.atmosphericPressure == nil)
        #expect(sensor.unitAtmosphericPressure == "hPa")
    }

    @Test func decodesHistoryPayload() throws {
        let data = Data("""
        {
            "ok": true,
            "device_id": "weatherbox-lab",
            "history": [
                {
                    "temperature": 24.7,
                    "humidity": 57.3,
                    "atmospheric_pressure": 1007.2,
                    "unit_temperature": "C",
                    "unit_humidity": "%",
                    "unit_atmospheric_pressure": "hPa",
                    "recorded_at": "2026-04-24T17:15:55.848998Z"
                }
            ],
            "count": 1,
            "retention_hours": 48
        }
        """.utf8)

        let historyResponse = try JSONDecoder().decode(SensorHistoryResponse.self, from: data)

        #expect(historyResponse.deviceId == "weatherbox-lab")
        #expect(historyResponse.history.count == 1)
        #expect(historyResponse.history[0].atmosphericPressure == 1007.2)
        #expect(historyResponse.retentionHours == 48)
    }

    @Test func accentColorRawValueStaysStable() {
        let option = AccentOption(rawValue: "mint")
        #expect(option == .mint)
    }

    @Test func classifiesComfortStatusForTypicalIndoorCases() {
        #expect(ComfortStatus(temperature: 23.0, humidity: 48.0) == .comfortable)
        #expect(ComfortStatus(temperature: 18.5, humidity: 47.0) == .normal)
        #expect(ComfortStatus(temperature: 22.0, humidity: 31.0) == .dry)
        #expect(ComfortStatus(temperature: 22.0, humidity: 68.0) == .humid)
        #expect(ComfortStatus(temperature: 27.5, humidity: 64.0) == .stuffy)
    }

    @Test func prefersDryAndStuffyBoundariesOverGenericStates() {
        #expect(ComfortStatus(temperature: 27.0, humidity: 34.0) == .dry)
        #expect(ComfortStatus(temperature: 26.0, humidity: 60.0) == .stuffy)
    }
}
