# IoT Device Integration — Form Spesifikasi

> **Untuk:** IoT Engineer yang mengembangkan firmware ESP8266
> **Tujuan:** Mengumpulkan semua informasi yang dibutuhkan agar device terintegrasi mulus dengan backend + broker MQTT.
> **Cara isi:** Jawab setiap pertanyaan di bagian `Jawaban:`. Kalau belum tahu/belum diputuskan, tulis "BELUM DITENTUKAN".
>
> Setiap section ada catatan **[Dampak]** — menjelaskan kenapa informasi ini penting dan apa yang terpengaruh kalau salah.

---

## 1. Device Inventory

Berapa unit ESP8266 fisik, dan masing-masing mewakili apa?

| Device fisik | device_id | location | Sensor terpasang |
|--------------|-----------|----------|------------------|
| ESP8266 #1 | _______ | _______ | _______ |
| ESP8266 #2 | _______ | _______ | _______ |

**[Dampak]** Menentukan jumlah MQTT credential + ACL rule yang dibuat di broker. Satu device = satu credential (best practice, supaya bisa di-revoke individual).

**Jawaban:**
```
(isi tabel di atas)
```

---

## 2. Nilai `location` (KRITIS)

`location` yang dikirim device **harus persis** salah satu dari string berikut (case-sensitive):

- `ruang_produksi`
- `ruang_penyolderan`
- `ruang_penyimpanan`

**[Dampak]** Alert rules di Grafana query dengan filter `location = 'ruang_penyolderan'` dan `location = 'ruang_produksi'` (hardcoded). Kalau device kirim string lain (typo, beda format seperti `production_room`), data **tetap masuk DB tapi alert tidak akan pernah nyala**. Silent failure.

**Pertanyaan:** Konfirmasi device akan pakai string persis di atas? Kalau location berbeda, sebutkan apa.

**Jawaban:**
```

```

---

## 3. Payload Format

Backend memvalidasi payload dengan schema ketat (Pydantic). Format JSON yang **wajib** dipenuhi:

```json
{
  "time": "2026-05-31T15:00:00Z",
  "device_id": "device_001",
  "location": "ruang_produksi",
  "temperature": 30.5,
  "humidity": 60.2,
  "accel_x": 0.01,
  "accel_y": -0.02,
  "accel_z": 9.81,
  "vibration_rms": 0.05,
  "flux_ppm": null,
  "flux_aqi": null,
  "voc_level": null
}
```

**Aturan field:**

| Field | Tipe | Range/Format | Wajib? |
|-------|------|--------------|--------|
| `time` | string ISO8601 | `2026-05-31T15:00:00Z` (UTC) | Ya |
| `device_id` | string | max 64 char | Ya |
| `location` | string | lihat section 2 | Ya |
| `temperature` | float/null | -10 s/d 100 (°C) | Null kalau no sensor |
| `humidity` | float/null | 0 s/d 100 (%RH) | Null kalau no sensor |
| `accel_x/y/z` | float/null | m/s² | Null kalau no sensor |
| `vibration_rms` | float/null | >= 0 (m/s²) | Null kalau no sensor |
| `flux_ppm` | float/null | >= 0 (ppm) | Null kalau no sensor |
| `flux_aqi` | int/null | 0 s/d 500 | Null kalau no sensor |
| `voc_level` | string/null | `GOOD`/`MODERATE`/`UNHEALTHY`/`HAZARDOUS` | Null kalau no sensor |

**[Dampak]** Kalau **satu field** di luar range (misal `temperature: 150`), Pydantic **reject SELURUH payload** — bukan cuma field itu. Seluruh reading di-drop. Field yang tidak ada sensornya **harus dikirim `null` atau di-omit**, jangan `0` (karena 0 = nilai valid, beda makna dengan "tidak ada sensor").

**Pertanyaan:** Bisa kirim payload persis format ini? Library JSON apa yang dipakai (ArduinoJson)?

**Jawaban:**
```

```

---

## 4. Timestamp

**[Dampak]** Backend **percaya `time` dari payload** (bukan waktu insert). Disimpan apa adanya ke DB. Kalau clock device salah, data masuk ke time-bucket yang salah → dashboard & alert kacau.

**Pertanyaan:**
- Device set timestamp sendiri via NTP? (wajib, juga dibutuhkan untuk TLS)
- Atau backend yang harus generate timestamp saat terima? (perlu perubahan backend)

**Jawaban:**
```

```

---

## 5. `voc_level` — Siapa yang Hitung?

`voc_level` adalah kategori dari `flux_ppm`:
- `GOOD` (≤10 ppm), `MODERATE` (≤35), `UNHEALTHY` (≤75), `HAZARDOUS` (>75)

**[Dampak]** Kalau device kirim `voc_level`, harus exact uppercase enum. Kalau tidak, bisa dihitung di backend dari `flux_ppm` (perlu sedikit perubahan backend).

**Pertanyaan:** Device hitung `voc_level` sendiri, atau backend yang derive dari `flux_ppm`?

**Jawaban:**
```

```

---

## 6. Sensor Sanity / Glitch Handling

Sensor real sering glitch: DHT22 kirim 255 saat read error, MQ-135 noisy saat warmup, dll.

**[Dampak]** Kalau reading glitch lewat range valid (section 3), seluruh payload di-drop. Bisa kehilangan data sensor lain yang sebenarnya valid di payload yang sama.

**Pertanyaan:**
- Apakah firmware filter/skip reading invalid sebelum publish? (misal: skip kalau DHT22 return NaN)
- Atau kirim apa adanya (backend yang handle)?

**Jawaban:**
```

```

---

## 7. Publish Frequency & QoS

**[Dampak]** Backend buffer + batch insert (flush tiap 5 detik atau 50 records). Frekuensi sangat tinggi dari banyak device bisa perlu tuning. QoS menentukan reliability.

**Pertanyaan:**
- Interval publish per device (detik)? (simulator: 2 detik)
- QoS level? (rekomendasi: QoS 1 = at-least-once)

**Jawaban:**
```

```

---

## 8. Aktuator / Downlink (PENTING — kemungkinan butuh backend baru)

README menyebut aktuator: LED, Buzzer, Motor Fan DC, Relay.

**[Dampak]** Saat ini backend **hanya consume** data sensor (uplink). Kalau aktuator dikontrol dari server (misal: nyalakan fan otomatis saat suhu tinggi), itu butuh **downlink path baru** yang BELUM ADA:
- Backend publish command ke topic (misal `iot/command/device_001/fan`)
- Device subscribe topic command
- Logic kapan trigger command

**Pertanyaan:**
- Apakah aktuator dikontrol dari server (remote), atau device handle sendiri lokal (misal: ESP8266 langsung nyalakan buzzer saat baca suhu tinggi, tanpa server)?
- Kalau remote: apa saja command yang dibutuhkan? Topic structure?

**Jawaban:**
```

```

---

## 9. Konektivitas TLS

Server sudah siap: `mqtt.chescloud.my.id:8883` (TLS), auth username/password.

**[Dampak]** ESP8266 + TLS (BearSSL) memory-tight. Perlu tuning (MFLN, buffer size). Cert ECDSA (Let's Encrypt) — perlu embed trust anchor ISRG Root X1.

**Pertanyaan:**
- Firmware sudah pakai `WiFiClientSecure` (BearSSL)?
- Sudah set `PubSubClient.setBufferSize()` > 256? (payload ~250 bytes)
- Heap free setelah TLS connect berapa? (monitor `ESP.getFreeHeap()`)

**Jawaban:**
```

```

---

## 10. Credentials

**[Dampak]** Per-device credential untuk audit + revocation. Akan di-generate di broker, lalu diberikan ke engineer untuk embed di firmware.

**Pertanyaan:** Konfirmasi naming credential yang diinginkan (default: sama dengan `device_id`, misal user `device_001`).

**Jawaban:**
```

```

---

## Ringkasan — Yang Mempengaruhi Backend

Tandai mana yang perlu perubahan backend berdasarkan jawaban di atas:

- [ ] Backend generate timestamp (kalau device tidak pakai NTP) — section 4
- [ ] Backend derive `voc_level` dari `flux_ppm` — section 5
- [ ] Backend loosen validation untuk handle sensor glitch — section 6
- [ ] Backend downlink path untuk kontrol aktuator — section 8
- [ ] Penyesuaian buffer/flush untuk publish frequency — section 7

---

## Kontak

Kalau ada pertanyaan soal kontrak integrasi ini, diskusikan dengan backend/infra owner sebelum mulai flash firmware ke production.
