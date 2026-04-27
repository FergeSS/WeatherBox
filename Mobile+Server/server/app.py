from __future__ import annotations

import argparse
import json
import threading
import uuid
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

DEFAULT_DEVICE_ID = "weatherbox-default"
DEFAULT_STALE_AFTER_SECONDS = 30
DEFAULT_HISTORY_RETENTION_HOURS = 48

STATUS_FIELDS = {
    "mode",
    "connected",
    "ip",
    "ap_ssid",
    "ap_password",
    "stored_ssid",
    "current_ssid",
}

SENSOR_FIELDS = {
    "temperature",
    "humidity",
    "atmospheric_pressure",
    "unit_temperature",
    "unit_humidity",
    "unit_atmospheric_pressure",
}


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def utc_now_iso() -> str:
    return utc_now().isoformat().replace("+00:00", "Z")


def parse_timestamp(value: str | None) -> datetime | None:
    if not value:
        return None

    normalized = value.replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(normalized)
    except ValueError:
        return None


def to_bool(value: Any, default: bool = False) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in {"1", "true", "yes", "y", "on"}:
            return True
        if lowered in {"0", "false", "no", "n", "off"}:
            return False
    return default


def require_object(payload: Any, field_name: str) -> dict[str, Any]:
    if payload is None:
        return {}
    if not isinstance(payload, dict):
        raise ValueError(f"{field_name}_must_be_object")
    return payload


def optional_float(value: Any, field_name: str) -> float | None:
    if value is None:
        return None

    try:
        return float(value)
    except (TypeError, ValueError) as error:
        raise ValueError(f"{field_name}_must_be_number") from error


class StateStore:
    def __init__(self, state_path: Path, history_retention_seconds: int) -> None:
        self.state_path = state_path
        self.history_retention_seconds = history_retention_seconds
        self._lock = threading.Lock()
        self._state = self._load()
        self._normalize_loaded_state()

    def _default_state(self) -> dict[str, Any]:
        return {"devices": {}}

    def _load(self) -> dict[str, Any]:
        if not self.state_path.exists():
            self.state_path.parent.mkdir(parents=True, exist_ok=True)
            state = self._default_state()
            self._write(state)
            return state

        try:
            with self.state_path.open("r", encoding="utf-8") as handle:
                state = json.load(handle)
        except (json.JSONDecodeError, OSError):
            state = self._default_state()
            self._write(state)
            return state

        if not isinstance(state, dict) or not isinstance(state.get("devices"), dict):
            state = self._default_state()
            self._write(state)

        return state

    def _write(self, state: dict[str, Any]) -> None:
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        with self.state_path.open("w", encoding="utf-8") as handle:
            json.dump(state, handle, ensure_ascii=False, indent=2)

    def _save_locked(self) -> None:
        self._write(self._state)

    def _normalize_loaded_state(self) -> None:
        devices = self._state.get("devices", {})
        if not isinstance(devices, dict):
            self._state = self._default_state()
            self._write(self._state)
            return

        changed = False
        for device_id in list(devices.keys()):
            device = devices.get(device_id)
            if not isinstance(device, dict):
                devices[device_id] = {
                    "status": None,
                    "sensor": None,
                    "last_seen": None,
                    "history": [],
                    "commands": [],
                }
                changed = True
                continue

            if "commands" not in device or not isinstance(device.get("commands"), list):
                device["commands"] = []
                changed = True

            if "history" not in device or not isinstance(device.get("history"), list):
                device["history"] = []
                changed = True

            if self._prune_history_locked(device):
                changed = True

        if changed:
            self._write(self._state)

    def _ensure_device_locked(self, device_id: str) -> dict[str, Any]:
        device = self._state["devices"].get(device_id)
        if isinstance(device, dict):
            device.setdefault("commands", [])
            device.setdefault("history", [])
            return device

        device = {
            "status": None,
            "sensor": None,
            "last_seen": None,
            "history": [],
            "commands": [],
        }
        self._state["devices"][device_id] = device
        return device

    def ingest(self, device_id: str, status: dict[str, Any] | None, sensor: dict[str, Any] | None) -> dict[str, Any]:
        if status is None and sensor is None:
            raise ValueError("telemetry_payload_is_empty")

        with self._lock:
            device = self._ensure_device_locked(device_id)
            last_seen = utc_now_iso()

            if status is not None:
                normalized_status = {
                    "mode": str(status.get("mode", "unknown")),
                    "connected": to_bool(status.get("connected"), default=True),
                    "ip": str(status.get("ip", "")),
                    "ap_ssid": str(status.get("ap_ssid", "")),
                    "ap_password": str(status.get("ap_password", "")),
                    "stored_ssid": str(status.get("stored_ssid", "")),
                    "current_ssid": str(status.get("current_ssid", "")),
                }
                device["status"] = normalized_status

            if sensor is not None:
                try:
                    temperature = float(sensor["temperature"])
                    humidity = float(sensor["humidity"])
                except KeyError as error:
                    missing_field = error.args[0]
                    raise ValueError(f"missing_{missing_field}") from error
                except (TypeError, ValueError) as error:
                    raise ValueError("sensor_values_must_be_numbers") from error

                atmospheric_pressure = optional_float(
                    sensor.get("atmospheric_pressure"),
                    "atmospheric_pressure",
                )
                normalized_sensor = {
                    "temperature": temperature,
                    "humidity": humidity,
                    "atmospheric_pressure": atmospheric_pressure,
                    "unit_temperature": str(sensor.get("unit_temperature", "C")),
                    "unit_humidity": str(sensor.get("unit_humidity", "%")),
                    "unit_atmospheric_pressure": str(sensor.get("unit_atmospheric_pressure", "hPa")),
                }
                device["sensor"] = normalized_sensor
                device["history"].append(
                    {
                        **normalized_sensor,
                        "recorded_at": last_seen,
                    }
                )
                self._prune_history_locked(device)

            device["last_seen"] = last_seen
            self._save_locked()

            return {
                "device_id": device_id,
                "last_seen": last_seen,
                "has_status": device["status"] is not None,
                "has_sensor": device["sensor"] is not None,
            }

    def get_status(self, device_id: str, stale_after_seconds: int) -> dict[str, Any] | None:
        with self._lock:
            device = self._state["devices"].get(device_id)
            if not isinstance(device, dict) or not isinstance(device.get("status"), dict):
                return None

            status = dict(device["status"])
            last_seen = device.get("last_seen")
            stale = self._is_stale(last_seen, stale_after_seconds)
            status["connected"] = bool(status.get("connected", False)) and not stale
            status["last_seen"] = last_seen
            status["stale"] = stale
            return status

    def get_sensor(self, device_id: str) -> dict[str, Any] | None:
        with self._lock:
            device = self._state["devices"].get(device_id)
            if not isinstance(device, dict) or not isinstance(device.get("sensor"), dict):
                return None

            sensor = dict(device["sensor"])
            sensor.setdefault("atmospheric_pressure", None)
            sensor.setdefault("unit_atmospheric_pressure", "hPa")
            sensor["last_seen"] = device.get("last_seen")
            return sensor

    def get_history(self, device_id: str) -> list[dict[str, Any]]:
        with self._lock:
            device = self._state["devices"].get(device_id)
            if not isinstance(device, dict):
                return []

            if self._prune_history_locked(device):
                self._save_locked()

            history = device.get("history", [])
            if not isinstance(history, list):
                return []

            return [dict(sample) for sample in history if isinstance(sample, dict)]

    def enqueue_command(self, device_id: str, command_type: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
        with self._lock:
            device = self._ensure_device_locked(device_id)
            command = {
                "id": uuid.uuid4().hex,
                "type": command_type,
                "payload": payload or {},
                "created_at": utc_now_iso(),
            }
            device["commands"].append(command)
            self._save_locked()
            return command

    def get_commands(self, device_id: str) -> list[dict[str, Any]]:
        with self._lock:
            device = self._state["devices"].get(device_id)
            if not isinstance(device, dict):
                return []
            commands = device.get("commands", [])
            if not isinstance(commands, list):
                return []
            return [dict(command) for command in commands if isinstance(command, dict)]

    def acknowledge_commands(self, device_id: str, command_ids: list[str]) -> int:
        ids = {command_id for command_id in command_ids if command_id}
        if not ids:
            return 0

        with self._lock:
            device = self._state["devices"].get(device_id)
            if not isinstance(device, dict):
                return 0

            commands = device.get("commands", [])
            if not isinstance(commands, list):
                return 0

            original_count = len(commands)
            device["commands"] = [
                command
                for command in commands
                if not isinstance(command, dict) or command.get("id") not in ids
            ]
            removed_count = original_count - len(device["commands"])
            if removed_count:
                self._save_locked()
            return removed_count

    def _is_stale(self, last_seen: str | None, stale_after_seconds: int) -> bool:
        last_seen_dt = parse_timestamp(last_seen)
        if last_seen_dt is None:
            return True
        age = (utc_now() - last_seen_dt).total_seconds()
        return age > stale_after_seconds

    def _prune_history_locked(self, device: dict[str, Any]) -> bool:
        history = device.get("history", [])
        if not isinstance(history, list):
            device["history"] = []
            return True

        cutoff = utc_now().timestamp() - self.history_retention_seconds
        original_count = len(history)
        filtered_history: list[dict[str, Any]] = []

        for sample in history:
            if not isinstance(sample, dict):
                continue

            recorded_at = sample.get("recorded_at")
            recorded_at_dt = parse_timestamp(recorded_at if isinstance(recorded_at, str) else None)
            if recorded_at_dt is None:
                continue

            if recorded_at_dt.timestamp() < cutoff:
                continue

            normalized_sample = dict(sample)
            normalized_sample.setdefault("atmospheric_pressure", None)
            normalized_sample.setdefault("unit_atmospheric_pressure", "hPa")
            filtered_history.append(normalized_sample)

        filtered_history.sort(key=lambda sample: sample.get("recorded_at", ""))
        device["history"] = filtered_history
        return len(filtered_history) != original_count


class WeatherBoxServer:
    def __init__(
        self,
        host: str,
        port: int,
        state_path: Path,
        stale_after_seconds: int = DEFAULT_STALE_AFTER_SECONDS,
        history_retention_hours: int = DEFAULT_HISTORY_RETENTION_HOURS,
    ) -> None:
        self.host = host
        self.port = port
        self.stale_after_seconds = stale_after_seconds
        self.history_retention_hours = history_retention_hours
        self.store = StateStore(state_path, history_retention_seconds=history_retention_hours * 3600)
        self.httpd = ThreadingHTTPServer((host, port), WeatherBoxRequestHandler)
        self.httpd.app = self  # type: ignore[attr-defined]

    @property
    def base_url(self) -> str:
        host, port = self.httpd.server_address[:2]
        return f"http://{host}:{port}"

    def serve_forever(self) -> None:
        self.httpd.serve_forever()

    def start_in_background(self) -> threading.Thread:
        thread = threading.Thread(target=self.serve_forever, daemon=True)
        thread.start()
        return thread

    def close(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()


class WeatherBoxRequestHandler(BaseHTTPRequestHandler):
    server_version = "WeatherBoxServer/0.1"

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)

        try:
            if parsed.path == "/health":
                self.respond(HTTPStatus.OK, {"ok": True, "message": "server_is_healthy"})
                return

            if parsed.path == "/status":
                self.handle_get_status(query)
                return

            if parsed.path == "/sensor":
                self.handle_get_sensor(query)
                return

            if parsed.path == "/history":
                self.handle_get_history(query)
                return

            if parsed.path == "/device/commands":
                self.handle_get_commands(query)
                return

            self.respond_not_found()
        except ValueError as error:
            self.respond_error(HTTPStatus.BAD_REQUEST, str(error))
        except Exception:
            self.respond_error(HTTPStatus.INTERNAL_SERVER_ERROR, "internal_server_error")

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)

        try:
            if parsed.path == "/ingest":
                self.handle_ingest(query)
                return

            if parsed.path == "/wifi":
                self.handle_wifi(query)
                return

            if parsed.path == "/reboot":
                self.handle_simple_command(query, "reboot", "reboot_command_queued")
                return

            if parsed.path == "/reset_wifi":
                self.handle_simple_command(query, "reset_wifi", "reset_wifi_command_queued")
                return

            if parsed.path == "/device/commands/ack":
                self.handle_ack_commands(query)
                return

            self.respond_not_found()
        except ValueError as error:
            self.respond_error(HTTPStatus.BAD_REQUEST, str(error))
        except Exception:
            self.respond_error(HTTPStatus.INTERNAL_SERVER_ERROR, "internal_server_error")

    def handle_get_status(self, query: dict[str, list[str]]) -> None:
        device_id = self.get_device_id(query=query)
        status = self.app.store.get_status(device_id, self.app.stale_after_seconds)
        if status is None:
            self.respond_error(HTTPStatus.NOT_FOUND, "no_status_yet")
            return
        self.respond(HTTPStatus.OK, status)

    def handle_get_sensor(self, query: dict[str, list[str]]) -> None:
        device_id = self.get_device_id(query=query)
        sensor = self.app.store.get_sensor(device_id)
        if sensor is None:
            self.respond_error(HTTPStatus.NOT_FOUND, "no_sensor_yet")
            return
        self.respond(HTTPStatus.OK, sensor)

    def handle_get_commands(self, query: dict[str, list[str]]) -> None:
        device_id = self.get_device_id(query=query)
        commands = self.app.store.get_commands(device_id)
        self.respond(
            HTTPStatus.OK,
            {
                "ok": True,
                "device_id": device_id,
                "commands": commands,
                "pending_count": len(commands),
            },
        )

    def handle_get_history(self, query: dict[str, list[str]]) -> None:
        device_id = self.get_device_id(query=query)
        history = self.app.store.get_history(device_id)
        self.respond(
            HTTPStatus.OK,
            {
                "ok": True,
                "device_id": device_id,
                "history": history,
                "count": len(history),
                "retention_hours": self.app.history_retention_hours,
            },
        )

    def handle_ingest(self, query: dict[str, list[str]]) -> None:
        payload = self.read_json_body()
        device_id = self.get_device_id(query=query, payload=payload)

        status_payload = self.extract_status_payload(payload)
        sensor_payload = self.extract_sensor_payload(payload)

        result = self.app.store.ingest(device_id, status_payload, sensor_payload)
        self.respond(
            HTTPStatus.OK,
            {
                "ok": True,
                "message": "telemetry_saved",
                **result,
            },
        )

    def handle_wifi(self, query: dict[str, list[str]]) -> None:
        payload = self.read_json_body()
        device_id = self.get_device_id(query=query, payload=payload)
        ssid = str(payload.get("ssid", "")).strip()
        if not ssid:
            raise ValueError("missing_ssid")

        password = str(payload.get("password", ""))
        command = self.app.store.enqueue_command(
            device_id,
            "wifi",
            {"ssid": ssid, "password": password},
        )

        self.respond(
            HTTPStatus.ACCEPTED,
            {
                "ok": True,
                "message": "wifi_command_queued",
                "ssid": ssid,
                "command_id": command["id"],
            },
        )

    def handle_simple_command(
        self,
        query: dict[str, list[str]],
        command_type: str,
        message: str,
    ) -> None:
        payload = self.read_json_body(allow_empty=True)
        device_id = self.get_device_id(query=query, payload=payload)
        command = self.app.store.enqueue_command(device_id, command_type)
        self.respond(
            HTTPStatus.ACCEPTED,
            {
                "ok": True,
                "message": message,
                "command_id": command["id"],
            },
        )

    def handle_ack_commands(self, query: dict[str, list[str]]) -> None:
        payload = self.read_json_body()
        device_id = self.get_device_id(query=query, payload=payload)
        command_ids = payload.get("command_ids")
        if not isinstance(command_ids, list):
            raise ValueError("command_ids_must_be_array")

        removed_count = self.app.store.acknowledge_commands(
            device_id,
            [str(command_id) for command_id in command_ids],
        )
        self.respond(
            HTTPStatus.OK,
            {
                "ok": True,
                "message": "commands_acknowledged",
                "removed_count": removed_count,
            },
        )

    def extract_status_payload(self, payload: dict[str, Any]) -> dict[str, Any] | None:
        nested = payload.get("status")
        if nested is not None:
            status_payload = require_object(nested, "status")
            return status_payload or None

        flat_payload = {field: payload[field] for field in STATUS_FIELDS if field in payload}
        return flat_payload or None

    def extract_sensor_payload(self, payload: dict[str, Any]) -> dict[str, Any] | None:
        nested = payload.get("sensor")
        if nested is not None:
            sensor_payload = require_object(nested, "sensor")
            return sensor_payload or None

        flat_payload = {field: payload[field] for field in SENSOR_FIELDS if field in payload}
        return flat_payload or None

    def read_json_body(self, allow_empty: bool = False) -> dict[str, Any]:
        content_length = int(self.headers.get("Content-Length", "0") or 0)
        raw_body = self.rfile.read(content_length) if content_length > 0 else b""

        if not raw_body:
            if allow_empty:
                return {}
            raise ValueError("request_body_is_required")

        try:
            payload = json.loads(raw_body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ValueError("invalid_json") from error

        if not isinstance(payload, dict):
            raise ValueError("json_body_must_be_object")

        return payload

    def get_device_id(
        self,
        query: dict[str, list[str]],
        payload: dict[str, Any] | None = None,
    ) -> str:
        query_device_id = first_query_value(query, "device_id")
        if query_device_id:
            return query_device_id

        payload_device_id = payload.get("device_id") if isinstance(payload, dict) else None
        if payload_device_id is not None:
            return str(payload_device_id)

        return DEFAULT_DEVICE_ID

    def respond(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status.value)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def respond_error(self, status: HTTPStatus, error_message: str) -> None:
        self.respond(status, {"ok": False, "error": error_message})

    def respond_not_found(self) -> None:
        self.respond_error(HTTPStatus.NOT_FOUND, "not_found")

    @property
    def app(self) -> WeatherBoxServer:
        return self.server.app  # type: ignore[attr-defined]

    def log_message(self, format: str, *args: Any) -> None:
        super().log_message(format, *args)


def first_query_value(query: dict[str, list[str]], key: str) -> str | None:
    values = query.get(key)
    if not values:
        return None
    value = values[0].strip()
    return value or None


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="WeatherBox backend server")
    parser.add_argument("--host", default="127.0.0.1", help="Bind host")
    parser.add_argument("--port", default=8080, type=int, help="Bind port")
    parser.add_argument(
        "--state-file",
        default=str(Path(__file__).with_name("data").joinpath("state.json")),
        help="Path to JSON file used for persisted state",
    )
    parser.add_argument(
        "--stale-after-seconds",
        default=DEFAULT_STALE_AFTER_SECONDS,
        type=int,
        help="After this number of seconds device is marked offline",
    )
    parser.add_argument(
        "--history-retention-hours",
        default=DEFAULT_HISTORY_RETENTION_HOURS,
        type=int,
        help="Number of hours of sensor history to retain",
    )
    return parser


def main() -> None:
    args = build_parser().parse_args()
    server = WeatherBoxServer(
        host=args.host,
        port=args.port,
        state_path=Path(args.state_file),
        stale_after_seconds=args.stale_after_seconds,
        history_retention_hours=args.history_retention_hours,
    )

    print(f"WeatherBox server listening on {server.base_url}")
    print(f"State file: {Path(args.state_file).resolve()}")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping server")
    finally:
        server.close()


if __name__ == "__main__":
    main()
