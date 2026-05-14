# iot-bigdata-project

Sistem monitoring manufaktur berbasis IoT dengan pipeline big data end-to-end, mulai dari ingestion data sensor secara real-time, penyimpanan time-series, batch analytics menggunakan Apache Spark, hingga visualisasi di Grafana.

---

## Latar Belakang

Sistem ini memonitor kondisi tiga ruangan di lingkungan manufaktur secara real-time menggunakan sensor suhu, kelembaban, getaran, dan kadar uap gas. Data yang terkumpul dianalisis secara batch menggunakan Apache Spark untuk menghasilkan insight seperti tren anomali, agregasi per device, dan perbandingan kondisi antar ruangan.

Project ini sekaligus menjadi eksperimen distributed computing dengan membandingkan performa Apache Spark dalam berbagai skenario jumlah worker.

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
Backend (FastAPI)               ← EC2 Node 1, bukan container
        │
        │  insert
        ▼
PostgreSQL + TimescaleDB        ← EC2 Node 1, container
        │
        ├── streaming replication
        │         ▼
        │   PostgreSQL Standby  ← EC2 Node 2, container
        │
        │  export Parquet
        ▼
Amazon S3 (Data Lake)
        │
        │  s3a:// read
        ▼
Apache Spark Cluster            ← EC2 Node 2 (master) + ephemeral workers
        │
        │  write hasil
        ▼
PostgreSQL PRIMARY (Node 1)
        │
        ▼
Grafana Dashboard               ← EC2 Node 1, container
```

---

## Infrastruktur Cloud

```
AWS ap-southeast-1 (Singapore)
└── VPC: 10.0.0.0/16
    └── Public Subnet: 10.0.1.0/24
        ├── Node 1 — c7i-flex.large (primary, always-on)
        │   ├── FastAPI Backend
        │   ├── Mosquitto MQTT
        │   ├── Grafana + Telegram Alerting
        │   ├── PostgreSQL PRIMARY (TimescaleDB)
        │   ├── Cloudflare Tunnel → grafana.cheshub.my.id
        │   └── Tailscale
        │
        ├── Node 2 — t3.small (standby + analytics, always-on)
        │   ├── PostgreSQL STANDBY (streaming replication)
        │   ├── Spark Master
        │   └── Tailscale
        │
        └── Worker Nodes — t3.small (ephemeral, otomatis via script)
            └── Spark Worker

Akses:
├── User    → Cloudflare Tunnel → grafana.cheshub.my.id
├── Admin   → Tailscale SSH (zero inbound port dari internet)
├── DB sync → internal VPC only (10.0.1.x)
└── S3      → via IAM Role (no hardcoded credentials)
```

---

## Tech Stack

| Layer          | Teknologi                              |
|----------------|----------------------------------------|
| Ingestion      | FastAPI, Paho MQTT                     |
| Message Broker | Eclipse Mosquitto                      |
| Database       | PostgreSQL 16 + TimescaleDB            |
| Replikasi DB   | PostgreSQL Streaming Replication       |
| Data Lake      | Amazon S3 (format Parquet, s3a://)     |
| Processing     | Apache Spark 3.5.8 (PySpark)           |
| Visualisasi    | Grafana + Telegram Alerting            |
| Infra lokal    | WSL, Docker, Docker Compose            |
| Infra cloud    | AWS EC2, VPC, S3, IAM                  |
| Akses & Tunnel | Cloudflare Tunnel, Tailscale           |
| Automasi       | Bash + AWS CLI                         |
| Bahasa         | Python 3.12                            |

---

## Sensor yang Dimonitor

| Sensor                | Field                                         |
|-----------------------|-----------------------------------------------|
| Suhu & Kelembaban     | `temperature` (°C), `humidity` (%RH)          |
| Accelerometer/Getaran | `accel_x/y/z` (m/s²), `vibration_rms` (m/s²) |
| Uap Gas (MQ-135)      | `flux_ppm` (ppm), `flux_aqi`, `voc_level`     |

---

## Hasil Eksperimen Spark Scaling

Dataset: 36.057 records (6 hari data sensor, 3 device)

| Skenario          | Workers | Execution Time | Speedup vs baseline |
|-------------------|---------|----------------|---------------------|
| Master only       | 0       | 26.04 detik    | baseline            |
| Master + 1 worker | 1       | 24.58 detik    | 1.06x               |
| Master + 2 worker | 2       | 23.27 detik    | 1.12x               |
| Master + 3 worker | 3       | 22.62 detik    | 1.15x               |
| Master + 4 worker | 4       | 21.51 detik    | 1.21x               |

**Analisis:** Speedup yang dihasilkan kecil dan menunjukkan pola diminishing returns — setiap worker tambahan memberikan manfaat yang semakin kecil. Ini disebabkan oleh dua faktor utama: dataset yang relatif kecil (36K records) untuk ukuran Spark, dan bottleneck di I/O (baca S3) bukan compute. Distributed computing memberikan manfaat lebih nyata pada dataset skala GB/TB dan job yang compute-intensive.

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
│   ├── export_to_parquet.py   # Export DB → Parquet → S3
│   ├── batch_analytics.py     # Spark job: S3 → analytics → DB
│   ├── run_with_worker.sh     # Automasi ephemeral worker
│   └── data/parquet/          # Temporary Parquet (tidak di-commit)
├── db/
│   └── init.sql          # Schema TimescaleDB
├── infra/
│   ├── docker-compose.yml
│   ├── .env.example
│   └── mosquitto/
│       └── mosquitto.conf
├── grafana/
│   └── provisioning/
│       ├── datasources/  # TimescaleDB datasource
│       ├── dashboards/   # Dashboard IoT monitoring
│       └── alerting/     # Alert rules + contact points (Telegram)
└── README.md
```

---

## Prerequisites

- Docker & Docker Compose
- Python 3.12+
- Java 21
- Apache Spark 3.5.8
- AWS CLI (untuk ephemeral worker automation)

> Dikembangkan di WSL Ubuntu 24.04 (lokal) dan Amazon Linux 2023 (EC2).

---

## Cara Menjalankan (Local)

**1. Clone repository**
```bash
git clone <repo-url>
cd iot-bigdata-project
```

**2. Siapkan environment variable**
```bash
cd infra
cp .env.example .env
# edit .env
```

**3. Jalankan base services**
```bash
docker compose up -d
```

**4. Jalankan backend**
```bash
cd backend && source .venv/bin/activate
uvicorn app.main:app --reload
```

**5. Jalankan simulator**
```bash
cd simulator && source .venv/bin/activate
python simulator.py
```

**6. Batch pipeline**
```bash
cd spark-jobs && source .venv/bin/activate

# Export DB → S3
python export_to_parquet.py

# Spark job local mode (tanpa worker)
spark-submit \
  --packages org.apache.hadoop:hadoop-aws:3.3.4,com.amazonaws:aws-java-sdk-bundle:1.12.261 \
  batch_analytics.py s3://iot-bigdata-datalake-kagebyo/raw/<file>.parquet 0

# Spark job dengan ephemeral worker (otomatis launch + terminate)
./run_with_worker.sh s3://iot-bigdata-datalake-kagebyo/raw/<file>.parquet 2
```

---

## Status Pengerjaan

| Phase | Scope                                           | Status      |
|-------|-------------------------------------------------|-------------|
| 0     | Persiapan: skema DB, infra, konfigurasi         | ✅ Selesai  |
| 1     | Backend FastAPI + MQTT consumer + simulator     | ✅ Selesai  |
| 1.5   | Grafana dashboard + Telegram alerting           | ✅ Selesai  |
| 2     | Batch pipeline lokal (Spark local mode)         | ✅ Selesai  |
| 3     | Deploy ke EC2 + replikasi DB                    | ✅ Selesai  |
| 4     | Integrasi S3 sebagai Data Lake                  | ✅ Selesai  |
| 5     | Multi-node Spark (ephemeral workers)            | ✅ Selesai  |
| 6     | Automasi ephemeral worker                       | ✅ Selesai  |
| 7     | Evaluasi & analisis hasil scaling               | 🔧 On going |

---

## Catatan

- `.env` tidak di-commit ke git. Gunakan `.env.example` sebagai acuan.
- `grafana/provisioning/alerting/contact-points.yaml` tidak di-commit. Gunakan `.example` sebagai acuan.
- `db/init.sql` hanya dieksekusi sekali saat container pertama dibuat. Reset: `docker compose down -v`.
- `spark-jobs/data/` tidak di-commit ke git.
- Spark job di Node 2 selalu write ke DB Primary (Node 1), standby PostgreSQL bersifat read-only.
- S3 access menggunakan IAM Role, tidak ada credentials yang disimpan di kode.
- Worker node bersifat ephemeral — di-launch otomatis saat job, di-terminate setelah selesai.
- Custom AMI worker (Amazon Linux 2023 + Java 21 + Spark 3.5.8)