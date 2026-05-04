# iot-bigdata-project

Sistem monitoring manufaktur produksi berbasis IoT dengan pipeline big data end-to-end, mulai dari ingestion data sensor secara real-time, penyimpanan time-series, batch analytics menggunakan Apache Spark, hingga visualisasi di Grafana.

---

## Latar Belakang

Lingkungan manufaktur menghasilkan data sensor secara terus-menerus: suhu, kelembaban, getaran, hingga kadar uap flux yang berbahaya bagi kesehatan. Data ini nilainya rendah kalau hanya dibaca satu per satu, tapi kalau dikumpulkan, disimpan, dan dianalisis dalam jumlah besar, bisa menghasilkan insight seperti tren anomali, pola paparan uap per shift, atau perbandingan kondisi antar bagian lingkungan produksi.

Project ini membangun infrastruktur untuk melakukan hal tersebut, sekaligus menjadi eksperimen distributed computing dengan membandingkan performa Apache Spark dalam skenario berbeda: master only, master + 1 worker, dan master + 2 worker.

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
Amazon S3 (Data Lake)
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
| Processing     | Apache Spark 3.5 (PySpark)             |
| Visualisasi    | Grafana                                |
| Infra lokal    | Docker, Docker Compose                 |
| Infra cloud    | AWS EC2                                |
| Bahasa         | Python 3.11+                           |

---

## Sensor yang Dimonitor

| Sensor                | Field                                         |
|-----------------------|-----------------------------------------------|
| Suhu & Kelembaban     | `temperature` (°C), `humidity` (%RH)          |
| Accelerometer/Getaran | `accel_x/y/z` (m/s²), `vibration_rms` (m/s²) |
| Uap Flux Solder       | `flux_ppm` (ppm), `flux_aqi`, `voc_level`     |

---

## Struktur Folder

```
iot-bigdata-project/
├── backend/              # FastAPI app + MQTT consumer
│   └── app/
│       ├── models/       # Pydantic schema (validasi payload)
│       ├── routes/       # HTTP endpoint
│       └── mqtt/         # MQTT consumer (subscribe & proses pesan)
├── simulator/            # Script simulasi IoT device
├── spark-jobs/           # PySpark batch analytics
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
- Python 3.11+
- pip + virtualenv

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
# edit .env, isi POSTGRES_USER, POSTGRES_PASSWORD, GRAFANA_ADMIN_USER, GRAFANA_ADMIN_PASSWORD
```

**3. Jalankan base services (database, MQTT broker, Grafana)**
```bash
docker compose up -d
```

**4. Verifikasi semua container berjalan**
```bash
docker container ps
```

**5. Verifikasi tabel database terbuat**
```bash
docker exec -it iot_timescaledb psql -U <POSTGRES_USER> -d iot_db -c "\dt"
```

**6. Akses Grafana**
Buka browser: `http://localhost:3000`
Login dengan kredensial yang kamu set di `.env`.

---

## Status Pengerjaan

| Phase | Scope                                      | Status      |
|-------|--------------------------------------------|-------------|
| 0     | Persiapan: skema DB, infra, konfigurasi    | ✅ Selesai  |
| 1     | Backend FastAPI + MQTT consumer + simulator| 🔧 On going |
| 2     | Batch pipeline lokal (Spark local mode)    | 🔜 Belum    |
| 3     | Deploy ke EC2 single node                  | 🔜 Belum    |
| 4     | Integrasi S3 sebagai Data Lake             | 🔜 Belum    |
| 5     | Multi-node Spark (ephemeral workers)       | 🔜 Belum    |
| 6     | Automasi ephemeral worker                  | 🔜 Belum    |
| 7     | Evaluasi & analisis hasil scaling          | 🔜 Belum    |

---

## Catatan

- File `.env` tidak di-commit ke git (sudah ada di `.gitignore`). Gunakan `.env.example` sebagai acuan.
- `db/init.sql` hanya dieksekusi sekali saat container TimescaleDB pertama kali dibuat. Kalau mau reset schema, hapus volume Docker terlebih dahulu: `docker compose down -v`.
