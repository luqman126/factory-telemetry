# IoT Device Integration - Form Spesifikasi

**Untuk:** IoT Engineer yang mengembangkan firmware ESP8266 **Tujuan:** Mengumpulkan semua informasi yang dibutuhkan agar device terintegrasi mulus dengan backend + broker MQTT. **Cara isi:** Jawab setiap pertanyaan di bagian Jawaban:. Kalau belum tahu/belum diputuskan, tulis "BELUM DITENTUKAN".

Setiap section ada catatan **\[Dampak\]** - menjelaskan kenapa informasi ini penting dan apa yang terpengaruh kalau salah.

## **1\. Device Inventory**

Berapa unit ESP8266 fisik, dan masing-masing mewakili apa?

| **Device fisik** | **device_id** | **location**                                                                   | **Sensor terpasang**                                                    |
| ---------------- | ------------- | ------------------------------------------------------------------------------ | ----------------------------------------------------------------------- |
| ESP8266 #1       | device_001    | ruang_produksi + ruang_penyimpanan <br>(publish payload terpisah per location) | Ruang produksi: DHT11, SW-420, MQ-2 <br>Ruang penyimpanan/gudang: DHT11 |
| ESP8266 #2       | device_002    | ruang_penyolderan                                                              | DHT11, MQ-135 (DO/digital)                                              |

**\[Dampak\]** Menentukan jumlah MQTT credential + ACL rule yang dibuat di broker. Satu device = satu credential (best practice, supaya bisa di-revoke individual).

**Jawaban:**

Tabel Device Inventory sudah diisi di atas. Total perangkat fisik: 2 unit ESP8266. ESP8266 #1 menangani ruang produksi dan ruang penyimpanan/gudang, sedangkan ESP8266 #2 menangani ruang penyolderan.

## **2\. Nilai location (KRITIS)**

location yang dikirim device **harus persis** salah satu dari string berikut (case-sensitive):

- ruang_produksi
- ruang_penyolderan
- ruang_penyimpanan

**\[Dampak\]** Alert rules di Grafana query dengan filter location = 'ruang_penyolderan' dan location = 'ruang_produksi' (hardcoded). Kalau device kirim string lain (typo, beda format seperti production_room), data **tetap masuk DB tapi alert tidak akan pernah nyala**. Silent failure.

**Pertanyaan:** Konfirmasi device akan pakai string persis di atas? Kalau location berbeda, sebutkan apa.

**Jawaban:**

Ya, device akan memakai string location persis sesuai daftar backend dan case-sensitive:  
\- ruang_produksi  
\- ruang_penyolderan  
\- ruang_penyimpanan  
<br/>Catatan implementasi: ESP8266 #1 akan mengirim payload terpisah untuk ruang_produksi dan ruang_penyimpanan. ESP8266 #2 akan mengirim payload untuk ruang_penyolderan.

## **3\. Payload Format**

Backend memvalidasi payload dengan schema ketat (Pydantic). Format JSON yang **wajib** dipenuhi:

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

**Aturan field:**

| Field         | Tipe           | Range/Format                      | Wajib?               |
| ------------- | -------------- | --------------------------------- | -------------------- |
| time          | string ISO8601 | 2026-05-31T15:00:00Z (UTC)        | Ya                   |
| device_id     | string         | max 64 char                       | Ya                   |
| location      | string         | lihat section 2                   | Ya                   |
| temperature   | float/null     | \-10 s/d 100 (°C)                 | Null kalau no sensor |
| humidity      | float/null     | 0 s/d 100 (%RH)                   | Null kalau no sensor |
| accel_x/y/z   | float/null     | m/s²                              | Null kalau no sensor |
| vibration_rms | float/null     | \>= 0 (m/s²)                      | Null kalau no sensor |
| flux_ppm      | float/null     | \>= 0 (ppm)                       | Null kalau no sensor |
| flux_aqi      | int/null       | 0 s/d 500                         | Null kalau no sensor |
| voc_level     | string/null    | GOOD/MODERATE/UNHEALTHY/HAZARDOUS | Null kalau no sensor |

**\[Dampak\]** Kalau **satu field** di luar range (misal temperature: 150), Pydantic **reject SELURUH payload** - bukan cuma field itu. Seluruh reading di-drop. Field yang tidak ada sensornya **harus dikirim null atau di-omit**, jangan 0 (karena 0 = nilai valid, beda makna dengan "tidak ada sensor").

**Pertanyaan:** Bisa kirim payload persis format ini? Library JSON apa yang dipakai (ArduinoJson)?

**Jawaban:**

Bisa, firmware akan mengikuti format JSON sesuai schema backend menggunakan ArduinoJson.  
<br/>Rencana mapping field:  
\- time: ISO8601 UTC dari NTP.  
\- device_id: device_001 atau device_002.  
\- location: salah satu string valid pada section 2.  
\- temperature: nilai suhu DHT11.  
\- humidity: null, karena firmware final tidak memakai kelembapan.  
\- accel_x, accel_y, accel_z: null, karena tidak ada sensor akselerometer.  
\- vibration_rms: untuk ruang_produksi, nilai digital SW-420 akan dipetakan sementara menjadi 1.0 saat getaran terdeteksi dan 0.0 saat normal. Untuk lokasi lain null.  
\- flux_ppm: null, karena sensor gas MQ-2/MQ-135 dipakai mode digital DO, bukan pembacaan ppm.  
\- flux_aqi: null.  
\- voc_level: GOOD saat gas/asap tidak terdeteksi, HAZARDOUS saat gas/asap terdeteksi. Untuk lokasi tanpa sensor gas, null.  
<br/>Catatan backend: jika backend membutuhkan nilai ppm asli, firmware harus diubah memakai AO/analog atau backend perlu menerima status digital gas sebagai voc_level saja.

## **4\. Timestamp**

**\[Dampak\]** Backend **percaya time dari payload** (bukan waktu insert). Disimpan apa adanya ke DB. Kalau clock device salah, data masuk ke time-bucket yang salah → dashboard & alert kacau.

**Pertanyaan:**

- Device set timestamp sendiri via NTP? (wajib, juga dibutuhkan untuk TLS)
- Atau backend yang harus generate timestamp saat terima? (perlu perubahan backend)

**Jawaban:**

Device akan set timestamp sendiri via NTP. Firmware perlu sinkronisasi NTP setelah WiFi tersambung dan sebelum publish data MQTT. Jika waktu belum tersinkron, device sebaiknya menunda publish agar data tidak masuk ke time-bucket yang salah.

## **5\. voc_level - Siapa yang Hitung?**

voc_level adalah kategori dari flux_ppm:

- GOOD (≤10 ppm), MODERATE (≤35), UNHEALTHY (≤75), HAZARDOUS (>75)

**\[Dampak\]** Kalau device kirim voc_level, harus exact uppercase enum. Kalau tidak, bisa dihitung di backend dari flux_ppm (perlu sedikit perubahan backend).

**Pertanyaan:** Device hitung voc_level sendiri, atau backend yang derive dari flux_ppm?

**Jawaban:**

Device akan menghitung voc_level sendiri. Karena MQ-2 dan MQ-135 digunakan pada mode DO/digital, kategori yang dikirim hanya:  
\- GOOD: gas/asap tidak terdeteksi  
\- HAZARDOUS: gas/asap terdeteksi  
<br/>Kategori MODERATE dan UNHEALTHY tidak dipakai pada mode digital karena tidak ada nilai ppm kontinu. flux_ppm dan flux_aqi dikirim null.

## **6\. Sensor Sanity / Glitch Handling**

Sensor real sering glitch: DHT22 kirim 255 saat read error, MQ-135 noisy saat warmup, dll.

**\[Dampak\]** Kalau reading glitch lewat range valid (section 3), seluruh payload di-drop. Bisa kehilangan data sensor lain yang sebenarnya valid di payload yang sama.

**Pertanyaan:**

- Apakah firmware filter/skip reading invalid sebelum publish? (misal: skip kalau DHT22 return NaN)
- Atau kirim apa adanya (backend yang handle)?

**Jawaban:**

Firmware akan melakukan filter/skip reading invalid sebelum publish.  
<br/>Aturan yang digunakan:  
\- Jika DHT11 return NaN, temperature dikirim null atau payload lokasi tersebut tidak dipublish sampai pembacaan valid.  
\- Nilai suhu hanya dikirim jika berada pada range backend (-10 sampai 100 derajat C).  
\- Sensor gas MQ-2/MQ-135 diberi waktu warm-up sebelum status gas digunakan.  
\- Field yang tidak ada sensornya dikirim null, bukan 0.  
<br/>Dengan ini backend tidak perlu menerima data glitch yang bisa menyebabkan seluruh payload direject.

## **7\. Publish Frequency & QoS**

**\[Dampak\]** Backend buffer + batch insert (flush tiap 5 detik atau 50 records). Frekuensi sangat tinggi dari banyak device bisa perlu tuning. QoS menentukan reliability.

**Pertanyaan:**

- Interval publish per device (detik)? (simulator: 2 detik)
- QoS level? (rekomendasi: QoS 1 = at-least-once)

**Jawaban:**

Interval publish yang disarankan: setiap 5 detik per payload/location.  
<br/>ESP8266 #1:  
\- publish payload ruang_produksi setiap 5 detik  
\- publish payload ruang_penyimpanan setiap 5 detik  
<br/>ESP8266 #2:  
\- publish payload ruang_penyolderan setiap 5 detik  
<br/>QoS: untuk implementasi awal dengan PubSubClient, publish menggunakan QoS 0 karena PubSubClient publish tidak mendukung QoS 1 secara penuh. Jika backend wajib QoS 1, firmware perlu memakai library MQTT lain yang mendukung QoS 1 untuk publish.

## **8\. Aktuator / Downlink (PENTING - kemungkinan butuh backend baru)**

README menyebut aktuator: LED, Buzzer, Motor Fan DC, Relay.

**\[Dampak\]** Saat ini backend **hanya consume** data sensor (uplink). Kalau aktuator dikontrol dari server (misal: nyalakan fan otomatis saat suhu tinggi), itu butuh **downlink path baru** yang BELUM ADA:

- Backend publish command ke topic (misal iot/command/device_001/fan)
- Device subscribe topic command
- Logic kapan trigger command

**Pertanyaan:**

- Apakah aktuator dikontrol dari server (remote), atau device handle sendiri lokal (misal: ESP8266 langsung nyalakan buzzer saat baca suhu tinggi, tanpa server)?
- Kalau remote: apa saja command yang dibutuhkan? Topic structure?

**Jawaban:**

Aktuator dikontrol lokal oleh device, bukan dari server. Jadi backend saat ini cukup menerima data sensor/uplink saja.  
<br/>Aturan lokal:  
\- ESP8266 #1: LED dan buzzer dikontrol langsung oleh ESP berdasarkan suhu, getaran SW-420, dan gas MQ-2.  
\- ESP8266 #2: LED dan buzzer dikontrol lokal oleh suhu DHT11; kipas DC dikontrol lokal oleh status gas/asap MQ-135.  
<br/>Untuk saat ini tidak diperlukan topic command/downlink. Jika nanti ingin remote control dari dashboard, backend baru perlu menambahkan command topic seperti iot/command/device_001/... dan iot/command/device_002/...

## **9\. Konektivitas TLS**

Server sudah siap: mqtt.chescloud.my.id:8883 (TLS), auth username/password.

**\[Dampak\]** ESP8266 + TLS (BearSSL) memory-tight. Perlu tuning (MFLN, buffer size). Cert ECDSA (Let's Encrypt) - perlu embed trust anchor ISRG Root X1.

**Pertanyaan:**

- Firmware sudah pakai WiFiClientSecure (BearSSL)?
- Sudah set PubSubClient.setBufferSize() > 256? (payload ~250 bytes)
- Heap free setelah TLS connect berapa? (monitor ESP.getFreeHeap())

**Jawaban:**

Belum diterapkan penuh pada firmware final saat ini; tahap saat ini masih integrasi lokal/non-TLS. Untuk production server mqtt.chescloud.my.id:8883, firmware perlu menggunakan WiFiClientSecure (BearSSL), trust anchor ISRG Root X1, dan NTP sebelum TLS connect.  
<br/>Rencana setting production:  
\- WiFiClientSecure (BearSSL): YA, akan digunakan untuk TLS.  
\- PubSubClient.setBufferSize(): minimal 512 byte, disarankan 768 atau 1024 byte agar aman untuk payload JSON.  
\- Heap free setelah TLS connect: BELUM DITENTUKAN / belum diuji, perlu dimonitor dengan ESP.getFreeHeap() pada firmware production.

## **10\. Credentials**

**\[Dampak\]** Per-device credential untuk audit + revocation. Akan di-generate di broker, lalu diberikan ke engineer untuk embed di firmware.

**Pertanyaan:** Konfirmasi naming credential yang diinginkan (default: sama dengan device_id, misal user device_001).

**Jawaban:**

Gunakan naming credential sama dengan device_id:  
\- username/device credential ESP8266 #1: device_001  
\- username/device credential ESP8266 #2: device_002  
<br/>Password dibuat oleh broker/infra owner dan di-embed ke firmware masing-masing device. Satu physical device menggunakan satu credential agar mudah audit dan revoke individual.

## **Ringkasan - Yang Mempengaruhi Backend**

Tandai mana yang perlu perubahan backend berdasarkan jawaban di atas:

- ☐ Backend generate timestamp (kalau device tidak pakai NTP) - section 4 - Tidak perlu, device memakai NTP.
- ☐ Backend derive voc_level dari flux_ppm - section 5 - Tidak perlu untuk saat ini, device mengirim voc_level dari status digital gas.
- ☐ Backend loosen validation untuk handle sensor glitch - section 6 - Tidak perlu untuk saat ini, firmware filter invalid dan kirim null.
- ☐ Backend downlink path untuk kontrol aktuator - section 8 - Tidak perlu untuk saat ini, aktuator dikontrol lokal.
- ☐ Penyesuaian buffer/flush untuk publish frequency - section 7 - Tidak perlu untuk 5 detik/device, kecuali nanti frekuensi publish dinaikkan.

## Kontak

Kalau ada pertanyaan soal kontrak integrasi ini, diskusikan dengan backend/infra owner sebelum mulai flash firmware ke production.