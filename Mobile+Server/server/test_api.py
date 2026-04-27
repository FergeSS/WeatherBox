from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from app import WeatherBoxServer


def request_json(
    url: str,
    method: str = "GET",
    payload: dict | None = None,
) -> tuple[int, dict]:
    body = None
    headers = {}
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    request = Request(url, data=body, headers=headers, method=method)

    try:
        with urlopen(request, timeout=3) as response:
            return response.status, json.loads(response.read().decode("utf-8"))
    except HTTPError as error:
        return error.code, json.loads(error.read().decode("utf-8"))


class WeatherBoxServerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        state_file = Path(self.temp_dir.name) / "state.json"
        self.server = WeatherBoxServer(
            host="127.0.0.1",
            port=0,
            state_path=state_file,
            stale_after_seconds=120,
            history_retention_hours=48,
        )
        self.server.start_in_background()
        self.base_url = self.server.base_url

    def tearDown(self) -> None:
        self.server.close()
        self.temp_dir.cleanup()

    def test_end_to_end_flow(self) -> None:
        status_code, health = request_json(f"{self.base_url}/health")
        self.assertEqual(status_code, 200)
        self.assertTrue(health["ok"])

        status_code, missing_status = request_json(f"{self.base_url}/status")
        self.assertEqual(status_code, 404)
        self.assertEqual(missing_status["error"], "no_status_yet")

        ingest_payload = {
            "device_id": "weatherbox-lab",
            "status": {
                "mode": "station",
                "connected": True,
                "ip": "10.0.0.77",
                "ap_ssid": "WeatherBox_AP",
                "ap_password": "12345678",
                "stored_ssid": "HomeWiFi",
                "current_ssid": "HomeWiFi",
            },
            "sensor": {
                "temperature": 24.7,
                "humidity": 57.3,
                "unit_temperature": "C",
                "unit_humidity": "%",
            },
        }
        status_code, ingest_result = request_json(
            f"{self.base_url}/ingest",
            method="POST",
            payload=ingest_payload,
        )
        self.assertEqual(status_code, 200)
        self.assertEqual(ingest_result["message"], "telemetry_saved")

        status_code, device_status = request_json(
            f"{self.base_url}/status?device_id=weatherbox-lab"
        )
        self.assertEqual(status_code, 200)
        self.assertEqual(device_status["mode"], "station")
        self.assertTrue(device_status["connected"])
        self.assertEqual(device_status["current_ssid"], "HomeWiFi")

        status_code, sensor = request_json(
            f"{self.base_url}/sensor?device_id=weatherbox-lab"
        )
        self.assertEqual(status_code, 200)
        self.assertEqual(sensor["temperature"], 24.7)
        self.assertEqual(sensor["humidity"], 57.3)
        self.assertIsNone(sensor["atmospheric_pressure"])
        self.assertEqual(sensor["unit_atmospheric_pressure"], "hPa")

        status_code, ingest_with_pressure = request_json(
            f"{self.base_url}/ingest",
            method="POST",
            payload={
                "device_id": "weatherbox-lab",
                "sensor": {
                    "temperature": 24.9,
                    "humidity": 56.8,
                    "atmospheric_pressure": 1007.2,
                    "unit_temperature": "C",
                    "unit_humidity": "%",
                    "unit_atmospheric_pressure": "hPa",
                },
            },
        )
        self.assertEqual(status_code, 200)
        self.assertEqual(ingest_with_pressure["message"], "telemetry_saved")

        status_code, sensor_with_pressure = request_json(
            f"{self.base_url}/sensor?device_id=weatherbox-lab"
        )
        self.assertEqual(status_code, 200)
        self.assertEqual(sensor_with_pressure["temperature"], 24.9)
        self.assertEqual(sensor_with_pressure["humidity"], 56.8)
        self.assertEqual(sensor_with_pressure["atmospheric_pressure"], 1007.2)
        self.assertEqual(sensor_with_pressure["unit_atmospheric_pressure"], "hPa")

        status_code, history = request_json(
            f"{self.base_url}/history?device_id=weatherbox-lab"
        )
        self.assertEqual(status_code, 200)
        self.assertEqual(history["count"], 2)
        self.assertEqual(history["retention_hours"], 48)
        self.assertEqual(history["history"][0]["temperature"], 24.7)
        self.assertEqual(history["history"][1]["atmospheric_pressure"], 1007.2)

        self.server.store._state["devices"]["weatherbox-lab"]["history"].append(
            {
                "temperature": 19.2,
                "humidity": 40.0,
                "atmospheric_pressure": 999.1,
                "unit_temperature": "C",
                "unit_humidity": "%",
                "unit_atmospheric_pressure": "hPa",
                "recorded_at": "2026-04-20T17:15:55.848998Z",
            }
        )

        status_code, pruned_history = request_json(
            f"{self.base_url}/history?device_id=weatherbox-lab"
        )
        self.assertEqual(status_code, 200)
        self.assertEqual(pruned_history["count"], 2)

        status_code, wifi_command = request_json(
            f"{self.base_url}/wifi?device_id=weatherbox-lab",
            method="POST",
            payload={"ssid": "OfficeWiFi", "password": "secret123"},
        )
        self.assertEqual(status_code, 202)
        self.assertEqual(wifi_command["message"], "wifi_command_queued")
        queued_command_id = wifi_command["command_id"]

        status_code, reboot_command = request_json(
            f"{self.base_url}/reboot?device_id=weatherbox-lab",
            method="POST",
            payload={},
        )
        self.assertEqual(status_code, 202)
        self.assertEqual(reboot_command["message"], "reboot_command_queued")

        status_code, commands = request_json(
            f"{self.base_url}/device/commands?device_id=weatherbox-lab"
        )
        self.assertEqual(status_code, 200)
        self.assertEqual(commands["pending_count"], 2)
        self.assertEqual(commands["commands"][0]["id"], queued_command_id)

        status_code, ack = request_json(
            f"{self.base_url}/device/commands/ack",
            method="POST",
            payload={
                "device_id": "weatherbox-lab",
                "command_ids": [queued_command_id],
            },
        )
        self.assertEqual(status_code, 200)
        self.assertEqual(ack["removed_count"], 1)

        status_code, commands_after_ack = request_json(
            f"{self.base_url}/device/commands?device_id=weatherbox-lab"
        )
        self.assertEqual(status_code, 200)
        self.assertEqual(commands_after_ack["pending_count"], 1)


if __name__ == "__main__":
    unittest.main()
