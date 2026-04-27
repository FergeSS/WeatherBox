#include <ESP8266WiFi.h>
#include <ESP8266HTTPClient.h>
#include <Wire.h>
#include <Adafruit_BMP085.h>
#include <DHT.h>

#define DHTPIN 5
#define DHTTYPE DHT11

#define I2C_SDA_PIN 14  // D5
#define I2C_SCL_PIN 12  // D6

struct WifiCredentials {
  const char* ssid;
  const char* password;
};

const WifiCredentials PRIMARY_WIFI = { "SashaVika", "MixoDGkd" };
const WifiCredentials BACKUP_WIFI  = { "FergeS", "55555555" };

const char* DEVICE_ID = "weatherbox-default";
const char* SERVER_BASE_URL = "http://5.129.195.241:18080";

const unsigned long WIFI_CONNECT_TIMEOUT_MS = 15000;
const unsigned long WIFI_RETRY_DELAY_MS = 3000;
const unsigned long TELEMETRY_INTERVAL_MS = 10000;
const unsigned long COMMANDS_POLL_INTERVAL_MS = 3000;
const uint16_t HTTP_TIMEOUT_MS = 5000;

const uint8_t LED_ON_LEVEL = LOW;
const uint8_t LED_OFF_LEVEL = HIGH;

DHT dht(DHTPIN, DHTTYPE);
Adafruit_BMP085 bmp;

bool pressureSensorReady = false;

unsigned long lastTelemetryAt = 0;
unsigned long lastCommandsPollAt = 0;

void logPrefix() {
  Serial.print("[");
  Serial.print(millis());
  Serial.print("] ");
}

void logLine(const String &msg) {
  logPrefix();
  Serial.println(msg);
}

void logLine(const __FlashStringHelper* msg) {
  logPrefix();
  Serial.println(msg);
}

void setLed(bool on) {
  digitalWrite(LED_BUILTIN, on ? LED_ON_LEVEL : LED_OFF_LEVEL);
}

String wifiStatusToString(int status) {
  switch (status) {
    case WL_IDLE_STATUS: return "WL_IDLE_STATUS";
    case WL_NO_SSID_AVAIL: return "WL_NO_SSID_AVAIL";
    case WL_SCAN_COMPLETED: return "WL_SCAN_COMPLETED";
    case WL_CONNECTED: return "WL_CONNECTED";
    case WL_CONNECT_FAILED: return "WL_CONNECT_FAILED";
    case WL_CONNECTION_LOST: return "WL_CONNECTION_LOST";
    case WL_DISCONNECTED: return "WL_DISCONNECTED";
    case WL_NO_SHIELD: return "WL_NO_SHIELD";
    default: return "UNKNOWN(" + String(status) + ")";
  }
}

String escapeJson(const String &s) {
  String out;
  out.reserve(s.length() + 8);

  for (size_t i = 0; i < s.length(); i++) {
    char c = s[i];
    if (c == '\"') out += "\\\"";
    else if (c == '\\') out += "\\\\";
    else if (c == '\n') out += "\\n";
    else if (c == '\r') out += "\\r";
    else if (c == '\t') out += "\\t";
    else out += c;
  }

  return out;
}

int findJsonStringEnd(const String &body, int startIndex) {
  int i = startIndex;
  while (i < body.length()) {
    int quotePos = body.indexOf('\"', i);
    if (quotePos < 0) return -1;
    if (quotePos == 0 || body[quotePos - 1] != '\\') return quotePos;
    i = quotePos + 1;
  }
  return -1;
}

String unescapeJsonString(String value) {
  value.replace("\\\"", "\"");
  value.replace("\\\\", "\\");
  value.replace("\\n", "\n");
  value.replace("\\r", "\r");
  value.replace("\\t", "\t");
  return value;
}

bool responseContainsTrue(const String &body, const char* key) {
  String withSpace = "\"" + String(key) + "\": true";
  String noSpace = "\"" + String(key) + "\":true";
  return body.indexOf(withSpace) >= 0 || body.indexOf(noSpace) >= 0;
}

int extractIntField(const String &body, const char* key) {
  String pattern = "\"" + String(key) + "\":";
  int pos = body.indexOf(pattern);
  if (pos < 0) return -1;

  pos += pattern.length();
  while (pos < body.length() && body[pos] == ' ') {
    pos++;
  }

  int end = pos;
  while (end < body.length() && isDigit(body[end])) {
    end++;
  }

  if (end == pos) return -1;
  return body.substring(pos, end).toInt();
}

void printVisibleNetworks(int count) {
  logPrefix();
  Serial.print("scanNetworks -> ");
  Serial.println(count);

  if (count <= 0) {
    logLine(F("No visible WiFi networks"));
    return;
  }

  for (int i = 0; i < count; i++) {
    logPrefix();
    Serial.print("  ");
    Serial.print(i + 1);
    Serial.print(". SSID='");
    Serial.print(WiFi.SSID(i));
    Serial.print("' RSSI=");
    Serial.print(WiFi.RSSI(i));
    Serial.print(" ENC=");
    Serial.println((int)WiFi.encryptionType(i));
  }
}

bool initPressureSensor() {
  logLine(F("Initializing BMP180 pressure sensor"));
  Wire.begin(I2C_SDA_PIN, I2C_SCL_PIN);

  logPrefix();
  Serial.print("I2C pins: SDA=GPIO");
  Serial.print(I2C_SDA_PIN);
  Serial.print(", SCL=GPIO");
  Serial.println(I2C_SCL_PIN);

  if (!bmp.begin()) {
    pressureSensorReady = false;
    logLine(F("BMP180 not found"));
    return false;
  }

  pressureSensorReady = true;
  logLine(F("BMP180 initialized successfully"));
  return true;
}


bool tryConnectToWifi(const WifiCredentials& wifi) {
  logPrefix();
  Serial.print("Trying WiFi: ");
  Serial.println(wifi.ssid);

  WiFi.disconnect();
  delay(300);

  WiFi.begin(wifi.ssid, wifi.password);

  unsigned long startedAt = millis();
  unsigned long lastBlinkAt = 0;
  unsigned long lastStatusAt = 0;
  bool ledState = false;

  while (WiFi.status() != WL_CONNECTED && millis() - startedAt < WIFI_CONNECT_TIMEOUT_MS) {
    unsigned long now = millis();

    if (now - lastBlinkAt >= 250) {
      ledState = !ledState;
      setLed(ledState);
      lastBlinkAt = now;
    }

    if (now - lastStatusAt >= 1000) {
      logPrefix();
      Serial.print("Connecting to '");
      Serial.print(wifi.ssid);
      Serial.print("' status=");
      Serial.println(wifiStatusToString(WiFi.status()));
      lastStatusAt = now;
    }

    delay(50);
    yield();
  }

  if (WiFi.status() == WL_CONNECTED) {
    setLed(false);
    logPrefix();
    Serial.print("Connected to ");
    Serial.println(wifi.ssid);

    logPrefix();
    Serial.print("Local IP: ");
    Serial.println(WiFi.localIP());

    logPrefix();
    Serial.print("RSSI: ");
    Serial.println(WiFi.RSSI());

    return true;
  }

  setLed(false);
  logPrefix();
  Serial.print("Failed to connect to ");
  Serial.print(wifi.ssid);
  Serial.print(", final status=");
  Serial.println(wifiStatusToString(WiFi.status()));
  return false;
}

void blinkLedDuringDelay(unsigned long totalDelayMs, unsigned long stepMs) {
  unsigned long startedAt = millis();
  bool ledState = false;

  while (millis() - startedAt < totalDelayMs) {
    ledState = !ledState;
    setLed(ledState);
    delay(stepMs);
    yield();
  }

  setLed(false);
}

void connectToWifiForever() {
  WiFi.mode(WIFI_STA);
  WiFi.persistent(false);
  WiFi.setAutoReconnect(true);

  logLine(F("Starting WiFi connection loop"));

  while (WiFi.status() != WL_CONNECTED) {
    bool primaryVisible = false;
    bool backupVisible = false;

    int networksCount = WiFi.scanNetworks();
    if (networksCount >= 0) {
      printVisibleNetworks(networksCount);

      for (int i = 0; i < networksCount; i++) {
        String foundSsid = WiFi.SSID(i);
        if (foundSsid == PRIMARY_WIFI.ssid) primaryVisible = true;
        if (foundSsid == BACKUP_WIFI.ssid) backupVisible = true;
      }

      WiFi.scanDelete();
    } else {
      logPrefix();
      Serial.print("scanNetworks failed, code=");
      Serial.println(networksCount);

      primaryVisible = true;
      backupVisible = true;
    }

    if (primaryVisible) {
      if (tryConnectToWifi(PRIMARY_WIFI)) {
        return;
      }
    } else {
      logPrefix();
      Serial.print("Primary network not found: ");
      Serial.println(PRIMARY_WIFI.ssid);
    }

    if (backupVisible) {
      if (tryConnectToWifi(BACKUP_WIFI)) {
        return;
      }
    } else {
      logPrefix();
      Serial.print("Backup network not found: ");
      Serial.println(BACKUP_WIFI.ssid);
    }

    logLine(F("WiFi not connected, retrying after pause"));
    blinkLedDuringDelay(WIFI_RETRY_DELAY_MS, 250);
  }
}

void ensureWifiConnected() {
  if (WiFi.status() == WL_CONNECTED) {
    return;
  }

  logPrefix();
  Serial.print("WiFi lost, status=");
  Serial.println(wifiStatusToString(WiFi.status()));

  setLed(false);
  connectToWifiForever();
}

String buildTelemetryPayload(
  bool hasSensor,
  float temperature,
  float humidity,
  bool hasPressure,
  float pressureHpa
) {
  String currentSsid = WiFi.status() == WL_CONNECTED ? WiFi.SSID() : "";
  String ip = WiFi.status() == WL_CONNECTED ? WiFi.localIP().toString() : "0.0.0.0";

  String payload;
  payload.reserve(448);

  payload += "{";
  payload += "\"device_id\":\"" + escapeJson(DEVICE_ID) + "\",";
  payload += "\"status\":{";
  payload += "\"mode\":\"station\",";
  payload += "\"connected\":" + String(WiFi.status() == WL_CONNECTED ? "true" : "false") + ",";
  payload += "\"ip\":\"" + escapeJson(ip) + "\",";
  payload += "\"ap_ssid\":\"\",";
  payload += "\"ap_password\":\"\",";
  payload += "\"stored_ssid\":\"" + escapeJson(currentSsid) + "\",";
  payload += "\"current_ssid\":\"" + escapeJson(currentSsid) + "\"";
  payload += "}";

  if (hasSensor) {
    payload += ",\"sensor\":{";
    payload += "\"temperature\":" + String(temperature, 1) + ",";
    payload += "\"humidity\":" + String(humidity, 1);

    if (hasPressure) {
      payload += ",\"atmospheric_pressure\":" + String(pressureHpa, 1);
    }

    payload += ",\"unit_temperature\":\"C\",";
    payload += "\"unit_humidity\":\"%\"";

    if (hasPressure) {
      payload += ",\"unit_atmospheric_pressure\":\"hPa\"";
    }

    payload += "}";
  }

  payload += "}";
  return payload;
}

bool postJson(const String &url, const String &payload, String *responseBody = nullptr) {
  WiFiClient client;
  HTTPClient http;
  http.setTimeout(HTTP_TIMEOUT_MS);

  logPrefix();
  Serial.print("POST ");
  Serial.print(url);
  Serial.print(" payload_bytes=");
  Serial.println(payload.length());

  if (!http.begin(client, url)) {
    logLine(F("HTTP begin failed"));
    return false;
  }

  http.addHeader("Content-Type", "application/json");
  int httpCode = http.POST(payload);

  String body = http.getString();

  logPrefix();
  Serial.print("POST ");
  Serial.print(url);
  Serial.print(" -> ");
  Serial.println(httpCode);

  if (body.length() > 0) {
    logLine(F("HTTP response body:"));
    Serial.println(body);
  }

  if (responseBody != nullptr) {
    *responseBody = body;
  }

  if (httpCode <= 0) {
    logPrefix();
    Serial.print("HTTP error: ");
    Serial.println(http.errorToString(httpCode));
    http.end();
    return false;
  }

  http.end();
  return httpCode >= 200 && httpCode < 300;
}

bool getRequest(const String &url, String &responseBody) {
  WiFiClient client;
  HTTPClient http;
  http.setTimeout(HTTP_TIMEOUT_MS);

  logPrefix();
  Serial.print("GET ");
  Serial.println(url);

  if (!http.begin(client, url)) {
    logLine(F("HTTP begin failed"));
    return false;
  }

  int httpCode = http.GET();
  responseBody = http.getString();

  logPrefix();
  Serial.print("GET ");
  Serial.print(url);
  Serial.print(" -> ");
  Serial.println(httpCode);

  if (httpCode <= 0) {
    logPrefix();
    Serial.print("HTTP error: ");
    Serial.println(http.errorToString(httpCode));
    http.end();
    return false;
  }

  http.end();
  return httpCode >= 200 && httpCode < 300;
}

void sendTelemetry() {
  logLine(F("Preparing telemetry"));
  logPrefix();
  Serial.print("Free heap: ");
  Serial.println(ESP.getFreeHeap());

  logPrefix();
  Serial.print("WiFi status: ");
  Serial.println(wifiStatusToString(WiFi.status()));

  if (WiFi.status() == WL_CONNECTED) {
    logPrefix();
    Serial.print("Current SSID: ");
    Serial.println(WiFi.SSID());

    logPrefix();
    Serial.print("Current IP: ");
    Serial.println(WiFi.localIP());
  }

  float humidity = dht.readHumidity();
  float temperature = dht.readTemperature();
  bool hasSensor = !(isnan(humidity) || isnan(temperature));

  logPrefix();
  Serial.print("DHT hasSensor=");
  Serial.println(hasSensor ? "true" : "false");

  if (hasSensor) {
    logPrefix();
    Serial.print("Temperature: ");
    Serial.println(temperature, 1);

    logPrefix();
    Serial.print("Humidity: ");
    Serial.println(humidity, 1);
  } else {
    logLine(F("DHT read failed, only status will be sent"));
  }

  float pressureHpa = NAN;
  bool hasPressure = false;

  if (pressureSensorReady) {
    pressureHpa = bmp.readPressure() / 100.0F;
    hasPressure = !isnan(pressureHpa) && pressureHpa > 0.0F;
  }

  logPrefix();
  Serial.print("BMP280 hasPressure=");
  Serial.println(hasPressure ? "true" : "false");

  if (hasPressure) {
    logPrefix();
    Serial.print("Pressure: ");
    Serial.println(pressureHpa, 1);
  } else if (pressureSensorReady) {
    logLine(F("BMP280 read failed"));
  } else {
    logLine(F("BMP280 is not initialized"));
  }

  String payload = buildTelemetryPayload(
    hasSensor,
    temperature,
    humidity,
    hasPressure,
    pressureHpa
  );

  logLine(F("Telemetry payload:"));
  Serial.println(payload);

  String response;
  bool postOk = postJson(String(SERVER_BASE_URL) + "/ingest", payload, &response);
  bool serverOk = responseContainsTrue(response, "ok");
  bool hasStatusOnServer = responseContainsTrue(response, "has_status");
  bool hasSensorOnServer = responseContainsTrue(response, "has_sensor");

  logPrefix();
  Serial.print("postOk=");
  Serial.print(postOk ? "true" : "false");
  Serial.print(" serverOk=");
  Serial.print(serverOk ? "true" : "false");
  Serial.print(" has_status=");
  Serial.print(hasStatusOnServer ? "true" : "false");
  Serial.print(" has_sensor=");
  Serial.println(hasSensorOnServer ? "true" : "false");

  if (postOk && hasSensor && hasSensorOnServer) {
    setLed(true);
    logLine(F("LED ON: WiFi connected and sensor data accepted by server"));
  } else {
    setLed(false);
    logLine(F("LED OFF: no confirmed sensor data on server"));
  }
}

bool extractNextCommand(const String &body, int &searchFrom, String &commandId, String &commandType) {
  int idPos = body.indexOf("\"id\":\"", searchFrom);
  if (idPos < 0) return false;

  int idStart = idPos + 6;
  int idEnd = findJsonStringEnd(body, idStart);
  if (idEnd < 0) return false;

  int typePos = body.indexOf("\"type\":\"", idEnd);
  if (typePos < 0) return false;

  int typeStart = typePos + 8;
  int typeEnd = findJsonStringEnd(body, typeStart);
  if (typeEnd < 0) return false;

  commandId = unescapeJsonString(body.substring(idStart, idEnd));
  commandType = unescapeJsonString(body.substring(typeStart, typeEnd));
  searchFrom = typeEnd + 1;

  return true;
}

bool ackCommand(const String &commandId) {
  String payload;
  payload.reserve(96);
  payload += "{";
  payload += "\"device_id\":\"" + escapeJson(DEVICE_ID) + "\",";
  payload += "\"command_ids\":[\"" + escapeJson(commandId) + "\"]";
  payload += "}";

  logPrefix();
  Serial.print("Acking command id=");
  Serial.println(commandId);

  String response;
  bool ok = postJson(String(SERVER_BASE_URL) + "/device/commands/ack", payload, &response);

  logPrefix();
  Serial.print("Ack result=");
  Serial.println(ok ? "true" : "false");

  return ok;
}

void processPendingCommands() {
  String response;
  String url = String(SERVER_BASE_URL) + "/device/commands?device_id=" + DEVICE_ID;

  bool ok = getRequest(url, response);
  if (!ok) {
    logLine(F("Commands poll failed"));
    return;
  }

  int pendingCount = extractIntField(response, "pending_count");
  logPrefix();
  Serial.print("Pending commands: ");
  Serial.println(pendingCount);

  if (pendingCount <= 0) {
    return;
  }

  logLine(F("Commands response body:"));
  Serial.println(response);

  int searchFrom = 0;
  String commandId;
  String commandType;

  while (extractNextCommand(response, searchFrom, commandId, commandType)) {
    logPrefix();
    Serial.print("Command received: type=");
    Serial.print(commandType);
    Serial.print(" id=");
    Serial.println(commandId);

    bool acked = ackCommand(commandId);
    if (!acked) {
      logLine(F("Command ack failed"));
      continue;
    }

    if (commandType == "reboot") {
      logLine(F("Executing reboot command"));
      delay(500);
      ESP.restart();
    }

    if (commandType == "wifi" || commandType == "reset_wifi") {
      logLine(F("Executing reconnect command"));
      setLed(false);
      WiFi.disconnect();
      delay(500);
      connectToWifiForever();
    }
  }
}

void setup() {
  Serial.begin(9600);
  pinMode(LED_BUILTIN, OUTPUT);
  setLed(false);

  delay(1000);

  logLine(F("Booting WeatherBox ESP8266"));
  logPrefix();
  Serial.print("Chip ID: ");
  Serial.println(ESP.getChipId(), HEX);

  logPrefix();
  Serial.print("Free heap at boot: ");
  Serial.println(ESP.getFreeHeap());

  dht.begin();
  logLine(F("DHT initialized"));

  initPressureSensor();
  connectToWifiForever();
  sendTelemetry();
}

void loop() {
  ensureWifiConnected();

  unsigned long now = millis();

  if (now - lastTelemetryAt >= TELEMETRY_INTERVAL_MS) {
    lastTelemetryAt = now;
    sendTelemetry();
  }

  if (now - lastCommandsPollAt >= COMMANDS_POLL_INTERVAL_MS) {
    lastCommandsPollAt = now;
    processPendingCommands();
  }

  delay(100);
}
