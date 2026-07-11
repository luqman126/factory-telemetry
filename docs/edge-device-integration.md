# IoT Edge Device Integration & Ingestion Reference

This document defines the interface standards, security rules, and data formats required for Edge microcontrollers (such as ESP8266 and ESP32) to stream data to the MQTT broker and ingestion backend.

---

## 1. Payload Schema Specification

The ingestion engine enforces strict data validation using Pydantic models at the API boundary. If a single field violates the schema rules, the **entire payload is rejected** to protect database integrity.

### JSON Payload Format
Edge devices must publish telemetry in the following JSON format:

```json
{  
  "time": "2026-07-10T12:00:00Z",  
  "device_id": "device_001",  
  "location": "ruang_produksi",  
  "temperature": null,  
  "humidity": null,  
  "accel_x": null,  
  "accel_y": null,  
  "accel_z": null,  
  "vibration_rms": null,  
  "flux_ppm": null,  
  "flux_aqi": null,  
  "voc_level": null  
}
```

### Data Fields Specification

| Parameter Name | Data Type | Physical Unit / Format | Mandatory? | Sensor Behavior |
|:---|:---|:---|:---|:---|
| `time` | String | ISO8601 UTC (`YYYY-MM-DDTHH:MM:SSZ`) | Yes | Synchronized via NTP |
| `device_id` | String | Maximum 64 characters | Yes | Hardcoded in firmware |
| `location` | String | Standard Location Enum | Yes | Must match valid locations |
| `temperature` | Float/Null | Degrees Celsius (°C) | No | Send `null` if sensor absent |
| `humidity` | Float/Null | Relative Humidity (%RH) | No | Send `null` if sensor absent |
| `accel_x/y/z` | Float/Null | Acceleration in $m/s^2$ | No | Send `null` if sensor absent |
| `vibration_rms`| Float/Null | RMS vibration amplitude | No | Send `null` if sensor absent |
| `flux_ppm` | Float/Null | Gas concentration in ppm | No | Send `null` if sensor absent |
| `flux_aqi` | Integer/Null| Air Quality Index (0 - 500) | No | Send `null` if sensor absent |
| `voc_level` | String/Null | `GOOD`/`MODERATE`/`UNHEALTHY`/`HAZARDOUS` | No | Send `null` if sensor absent |

> **Critical Guideline:** If a sensor is absent, send `null` or omit the key entirely. Do not send `0` for absent sensors, as `0` is a valid numerical reading (e.g., $0.0^\circ\text{C}$ temperature or $0.0\text{ m/s}^2$ acceleration).

---

## 2. Location String Constraints

To ensure alert routing and analytical metrics evaluate correctly, the `location` string must match one of the following enums exactly (case-sensitive):

- `ruang_produksi` (Production Area)
- `ruang_penyolderan` (Soldering Area)
- `ruang_penyimpanan` (Storage Area)

> **Impact of Typos:** If an Edge device sends a misspelled string (e.g., `ruang-produksi` or `production_room`), the database will store it, but Grafana Alert Manager queries (which rely on hardcoded enums) will fail to trigger.

---

## 3. Timestamp Synchronization (NTP)

- **Ingestion Rule:** The backend writes the timestamp provided by the Edge device in the `time` field. It does not overwrite it with the server's arrival time.
- **Firmware Requirement:** Microcontrollers must run an NTP client library (such as `NTPClient.h` in Arduino) to synchronize their internal clock to UTC via network time servers at boot. If the clock is desynchronized, the data will be archived in the wrong TimescaleDB time-buckets, corrupting Grafana panels.

---

## 4. Edge Sensor Behavior Specifications

### 1. Temperature & Humidity (DHT11 / DHT22)
- **Scale:** Celsius (°C)
- **Validation range:** -10.0 to 100.0 °C.
- **Glitch handling:** If the sensor library returns `NaN` or a value outside the valid range, send `null` or skip the publish event.

### 2. Vibration (SW-420)
- **Mapping:** The SW-420 digital output is mapped to `vibration_rms` values.
- **Rules:** When getaran (vibration) is active, map it to `1.0`. When normal, map it to `0.0`. All other locations should send `null`.

### 3. Gas Sensors (MQ-2 / MQ-135)
- **Operation:** Used in digital DO mode (threshold status) rather than continuous analog ppm mode.
- **AQI & PPM:** Send `null` for `flux_ppm` and `flux_aqi`.
- **VOC Level Mapping:** Map digital triggers to the `voc_level` enum:
  - Send `GOOD` when no gas/smoke is detected.
  - Send `MODERATE` when a minor threshold is exceeded but below the danger level.
  - Send `UNHEALTHY` when gas/smoke concentration reaches an unsafe level.
  - Send `HAZARDOUS` when gas/smoke threshold is critically breached.
- **Warmup:** Firmware must wait for the sensor warmup duration to complete before sending data.

---

## 5. MQTT Broker Connection Details

### Environment Matrix
Firmware configurations must target the appropriate broker host depending on the target environment:

| Environment | Broker Host | Port | Transport Security |
|:---|:---|:---|:---|
| **Staging** | `<staging-mqtt-domain>` | `8883` | MQTT over TLS |
| **Production** | `<production-mqtt-domain>` | `8883` | MQTT over TLS |

> **Firmware Best Practice:** Never hardcode connection URLs or credentials directly in the core logic. Define them in a separate configuration header file (e.g., `config.h` or via build flags like `-DENV_MQTT_HOST`) so the same binary code can target different environments.

- **Authentication:** Username/Password credentials are provisioned per device.
- **Authorization (ACLs):**
  - Publish allowed to: `iot/telemetry/+`
  - Subscribe allowed to: `iot/commands/<device_id>/+`

### TLS Implementation Details
Firmware must use `WiFiClientSecure` (BearSSL on ESP8266) and embed the Let's Encrypt ISRG Root X1 root certificate as a trust anchor. The client buffer size must be configured to at least 512 bytes (recommended 768 or 1024 bytes) to accommodate the JSON payload.
