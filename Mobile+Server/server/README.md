# WeatherBox Server

Простой backend для схемы:

- Arduino отправляет телеметрию на сервер
- iOS-приложение читает данные с сервера
- приложение кладёт команды на сервер, а устройство потом их забирает

Сервер написан без внешних зависимостей и запускается штатным `python3`.

## Запуск

```bash
python3 server/app.py
```

По умолчанию сервер слушает `http://127.0.0.1:8080`.

Если `8080` занят, можно поднять на другом порту:

```bash
python3 server/app.py --port 18080
```

## Основные ручки

- `GET /health` - healthcheck
- `POST /ingest` - Arduino отправляет статус и/или показания датчика
- `GET /status` - приложение читает статус устройства
- `GET /sensor` - приложение читает последние показания датчика
- `GET /history` - приложение читает историю показаний за последние 48 часов
- `POST /wifi` - приложение ставит команду смены Wi-Fi в очередь
- `POST /reboot` - приложение ставит команду перезагрузки в очередь
- `POST /reset_wifi` - приложение ставит команду сброса Wi-Fi в очередь
- `GET /device/commands` - устройство читает очередь команд
- `POST /device/commands/ack` - устройство подтверждает выполненные команды

## Пример отправки телеметрии

```bash
curl -X POST http://127.0.0.1:8080/ingest \
  -H 'Content-Type: application/json' \
  -d '{
    "device_id": "weatherbox-lab",
    "status": {
      "mode": "station",
      "connected": true,
      "ip": "10.0.0.77",
      "ap_ssid": "WeatherBox_AP",
      "ap_password": "12345678",
      "stored_ssid": "HomeWiFi",
      "current_ssid": "HomeWiFi"
    },
    "sensor": {
      "temperature": 24.7,
      "humidity": 57.3,
      "atmospheric_pressure": 1007.2,
      "unit_temperature": "C",
      "unit_humidity": "%",
      "unit_atmospheric_pressure": "hPa"
    }
  }'
```

`atmospheric_pressure` пока необязателен. Если Arduino его ещё не отправляет, backend примет payload и без этого поля, а в ответе `/sensor` вернёт `"atmospheric_pressure": null`.

## Пример чтения данных приложением

```bash
curl http://127.0.0.1:8080/status?device_id=weatherbox-lab
curl http://127.0.0.1:8080/sensor?device_id=weatherbox-lab
curl http://127.0.0.1:8080/history?device_id=weatherbox-lab
```

История сенсора хранится на backend 48 часов и автоматически обрезается по `recorded_at`.
