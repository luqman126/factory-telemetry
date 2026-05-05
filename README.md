# iot-bigdata-project

Sistem monitoring manufaktur berbasis IoT dengan pipeline big data end-to-end — mulai dari ingestion data sensor secara real-time, penyimpanan time-series, batch analytics menggunakan Apache Spark, hingga visualisasi di Grafana.

---

## Latar Belakang

Sistem ini memonitor kondisi tiga ruangan di lingkungan manufaktur secara real-time menggunakan sensor suhu, kelembaban, getaran, dan kadar uap gas. Data yang terkumpul dianalisis secara batch menggunakan Apache Spark untuk menghasilkan insight seperti tren anomali, agregasi per device, dan perbandingan kondisi antar ruangan.

Project ini sekaligus menjadi eksperimen distributed computing dengan membandingkan performa Apache Spark dalam skenario berbeda: master only, master + 1 worker, dan master + 2 worker.

---

## Ruangan yang Dimonitor

| Ruangan              | Sensor                  | Aktuator                    |
|----------------------|-------------------------|-----------------------------|
| Ruang Produksi Utama | DHT22, MPU6050          | LED, Buzzer                 |
| Ruang Penyolderan    | DHT22, MQ-135           | LED, Buzzer, Motor Fan DC   |
| Ruang Penyimpanan    | DHT22                   | LED, Buzzer                 |

> Hardware: ESP32 (x1), Relay. Device fisik masih dalam pengembangan — saat ini menggunakan simulator.

---

## Arsitektur

```
IoT Device / Simulator
        │
        │  MQTT
        ▼
Backend (FastAPI)          ← jalan di WSL / EC2, bukan container
        │
        │  insert
        ▼
PostgreSQL + TimescaleDB   ← container
        │
        │  export Parquet
        ▼
Amazon S3 (Data Lake)      ← Phase 4
        │
        │  read
        ▼
Apache Spark Cluster       ← master + ephemeral workers di EC2
        │
        │  write hasil
        ▼
PostgreSQL + TimescaleDB
        │
        ▼
Grafana Dashboard          ← container
```

---

## Tech Stack

| Layer          | Teknologi                              |
|----------------|----------------------------------------|
| Ingestion      | FastAPI, Paho MQTT                     |
| Message Broker | Eclipse Mosquitto                      |
| Database       | PostgreSQL 16 + TimescaleDB            |
| Data Lake      | Amazon S3 (format Parquet)             |
| Processing     | Apache Spark 3.5.8 (PySpark)          |
| Visualisasi    | Grafana                                |
| Infra lokal    | Docker, Docker Compose                 |
| Infra cloud    | AWS EC2                                |
| Bahasa         | Python 3.12                            |

---

## Sensor yang Dimonitor

| Sensor                | Field                                         |
|-----------------------|-----------------------------------------------|
| Suhu & Kelembaban     | `temperature` (°C), `humidity` (%RH)          |
| Accelerometer/Getaran | `accel_x/y/z` (m/s²), `vibration_rms` (m/s²) |
| Uap Gas (MQ-135)      | `flux_ppm` (ppm), `flux_aqi`, `voc_level`     |

---

## Struktur Folder

```
iot-bigdata-project/
├── backend/              # FastAPI app + MQTT consumer
│   └── app/
│       ├── main.py       # Entry point, startup/shutdown
│       ├── db.py         # Connection pool ke TimescaleDB
│       ├── models/       # Pydantic schema (validasi payload)
│       ├── routes/       # HTTP endpoint
│       └── mqtt/         # MQTT consumer (subscribe & proses pesan)
├── simulator/            # Script simulasi 3 device IoT
├── spark-jobs/           # PySpark batch analytics
│   ├── export_to_parquet.py  # Export DB → Parquet
│   ├── batch_analytics.py    # Spark job: Parquet → analytics → DB
│   └── data/parquet/         # Output file Parquet (tidak di-commit)
├── db/
│   └── init.sql          # Schema TimescaleDB (auto-run saat DB pertama dibuat)
├── infra/
│   ├── docker-compose.yml
│   ├── .env.example      # Template environment variable
│   └── mosquitto/
│       └── mosquitto.conf
├── grafana/
│   └── provisioning/     # Konfigurasi datasource & dashboard Grafana
└── README.md
```

---

## Prerequisites

Pastikan sudah terinstall di sistem kamu:

- Docker & Docker Compose
- Python 3.12+
- Java 21 (untuk Apache Spark)
- Apache Spark 3.5.8

> Project ini dikembangkan di WSL Ubuntu 24.04. Untuk environment lain mungkin ada penyesuaian kecil.

---

## Cara Menjalankan (Local)

**1. Clone repository dan masuk ke folder project**
```bash
git clone <repo-url>
cd iot-bigdata-project
```

**2. Siapkan environment variable**
```bash
cd infra
cp .env.example .env
# edit .env — isi POSTGRES_USER, POSTGRES_PASSWORD, GRAFANA_ADMIN_USER, GRAFANA_ADMIN_PASSWORD
```

**3. Jalankan base services (database, MQTT broker, Grafana)**
```bash
docker compose up -d
```

**4. Jalankan backend**
```bash
cd backend
source .venv/bin/activate
uvicorn app.main:app --reload
```

**5. Jalankan simulator**
```bash
cd simulator
source .venv/bin/activate
python simulator.py
```

**6. Jalankan batch pipeline (opsional)**
```bash
cd spark-jobs
source .venv/bin/activate

# Export data dari DB ke Parquet
python export_to_parquet.py

# Jalankan Spark job
spark-submit batch_analytics.py data/parquet/<nama_file>.parquet 0
```

**7. Akses Grafana**
Buka browser: `http://localhost:3000`
Login dengan kredensial yang kamu set di `.env`.

---

## Status Pengerjaan

| Phase | Scope                                           | Status      |
|-------|-------------------------------------------------|-------------|
| 0     | Persiapan: skema DB, infra, konfigurasi         | ✅ Selesai  |
| 1     | Backend FastAPI + MQTT consumer + simulator     | ✅ Selesai  |
| 2     | Batch pipeline lokal (Spark local mode)         | ✅ Selesai  |
| 3     | Deploy ke EC2 single node + replikasi DB        | 🔧 On going |
| 4     | Integrasi S3 sebagai Data Lake                  | 🔜 Belum    |
| 5     | Multi-node Spark (ephemeral workers)            | 🔜 Belum    |
| 6     | Automasi ephemeral worker                       | 🔜 Belum    |
| 7     | Evaluasi & analisis hasil scaling               | 🔜 Belum    |

---

## Catatan

- File `.env` tidak di-commit ke git. Gunakan `.env.example` sebagai acuan.
- `db/init.sql` hanya dieksekusi sekali saat container TimescaleDB pertama kali dibuat. Untuk reset schema: `docker compose down -v`.
- `spark-jobs/data/` tidak di-commit ke git — tambahkan ke `.gitignore`.
- Threshold anomali dan baseline sensor simulator dapat disesuaikan di `batch_analytics.py` dan `simulator/simulator.py`.