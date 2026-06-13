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

### 1. Aliran Data Utama (Sistem Big Data)

```text
 ┌────────────────────────┐
 │ IoT Device / Simulator │
 └──────────┬─────────────┘
            │ MQTT (TLS: Port 8883)
            ▼
 ┌────────────────────────┐
 │    FastAPI Backend     │
 │      (applayer-1)      │
 └──────────┬─────────────┘
            │ 1. Insert data sensor mentah (real-time)
            ▼
 ┌────────────────────────┐
 │  Postgres TimescaleDB  │◄── 5. JDBC Write ──┐
 │   Primary (datalayer-1)│     (Agregasi/     │
 └──────────┬─────────────┘      Anomali)      │
            │                                  │
            │ 2. Streaming                     │
            │    Replication                   │
            ▼                                  │
 ┌────────────────────────┐                    │
 │  Postgres TimescaleDB  │                    │
 │   Replica (datalayer-2)│                    │
 └──────────┬─────────────┘                    │
            │                                  │
            │ 3. Export                        │
            │    (Hourly Parquet)              │
            ▼                                  │
 ┌────────────────────────┐                    │
 │ Amazon S3 (Data Lake)  │                    │
 └──────────┬─────────────┘                    │
            │                                  │
            │ 4. Read (s3a://)                 │
            ▼                                  │
 ┌────────────────────────┐                    │
 │      Apache Spark      ├────────────────────┘
 │   Local (applayer-1)   │
 └────────────────────────┘
```

### 2. Alur Monitoring & Dashboard Visualisasi

```text
 ┌──────────────────────────────────────────────────────────────┐
 │                  Grafana Alloy Host Agent                    │
 │  (Terinstall di: applayer-1, datalayer-1, & datalayer-2)     │
 └──────────────────────────────┬───────────────────────────────┘
                                │
                                │ 8. Push Metrics (remote_write)
                                ▼
 ┌──────────────────────────────────────────────────────────────┐
 │                Prometheus Server (applayer-1)                │
 └──────────────────────────────┬───────────────────────────────┘
                                │
                                │ 7. Query Metrics
                                ▼
 ┌──────────────────────────────────────────────────────────────┐
 │                  Grafana Dashboard (applayer-1)              │
 └──────────────────────────────▲───────────────────────────────┘
                                │
                                │ 6. Query Analytics & Raw Data
                                │
 ┌──────────────────────────────┴───────────────────────────────┐
 │               TimescaleDB Primary (datalayer-1)              │
 └──────────────────────────────────────────────────────────────┘
```

---

## Infrastruktur Cloud

```text
AWS ap-southeast-1 (Singapore)
└── VPC: 10.0.0.0/16
    ├── Public Subnet: 10.0.1.0/24
    │   └── iot-bigdata-applayer-1 — c7i-flex.large (always-on)
    │       ├── FastAPI Backend & MQTT consumer
    │       ├── Mosquitto MQTT broker (Port TLS 8883)
    │       ├── Grafana + Telegram Alerting
    │       ├── Prometheus Server
    │       ├── Grafana Alloy agent
    │       ├── Spark Master (Local execution engine)
    │       ├── Cloudflare Tunnel → grafana.chescloud.my.id
    │       └── Tailscale (Bastion Host / SSH entry point)
    │
    └── Private Subnet: 10.0.2.0/24 (tanpa akses internet)
        ├── iot-bigdata-datalayer-1 — t3.small (always-on)
        │   ├── PostgreSQL PRIMARY (TimescaleDB, bare-metal)
        │   └── Grafana Alloy agent (dengan Postgres exporter)
        │
        ├── iot-bigdata-datalayer-2 — t3.small (always-on)
        │   ├── PostgreSQL STANDBY (streaming replication, read-only)
        │   └── Grafana Alloy agent (dengan Postgres exporter)
        │
        └── Worker Nodes — t3.small (ephemeral)
            └── Spark Worker (Auto launch/terminate via run_with_worker.sh)

Akses:
├── User    → Cloudflare Tunnel → grafana.chescloud.my.id
├── Admin   → Tailscale SSH → applayer-1 (Bastion) → jump ke 10.0.2.x
├── DB sync → internal VPC only (10.0.2.x)
└── S3      → VPC Gateway Endpoint (gratis, tanpa internet)
```

---

## Tech Stack

| Layer          | Teknologi                              | Keterangan |
|----------------|----------------------------------------|------------|
| Ingestion      | FastAPI, Paho MQTT                     | API ingest data & broker consumer |
| Message Broker | Eclipse Mosquitto                      | MQTT broker dengan TLS port 8883 |
| Database       | PostgreSQL 16 + TimescaleDB            | Penyimpanan data time-series ter-hypertable |
| Replikasi DB   | PostgreSQL Streaming Replication       | Sinkronisasi primary-standby secara real-time |
| Data Lake      | Amazon S3 (format Parquet, s3a://)     | Penyimpanan data batch terkompresi |
| Processing     | Apache Spark 3.5.8 (PySpark)           | Mesin analisis agregasi & anomali |
| Monitoring     | Prometheus Server & Grafana Alloy      | Pengumpul & penyimpan metrik host + database |
| Visualisasi    | Grafana + Telegram Alerting            | Dashboard server & data analitik |
| Infra lokal    | WSL, Docker, Docker Compose            | Development environment |
| Infra cloud    | AWS EC2, VPC, S3, IAM, VPC Endpoint  | Cloud infrastructure |
| Akses & Tunnel | Cloudflare Tunnel, Tailscale           | Secure tunnel & VPN admin (Bastion) |
| Automasi       | Bash, AWS CLI, Systemd Timer           | Script provisioning & orkestrator pipeline |
| Bahasa         | Python 3.12                            | Backend & PySpark scripting |

---

## Sensor yang Dimonitor

| Sensor | Field | Tipe Data | Keterangan / Rentang Nilai |
|---|---|---|---|
| Suhu (DHT22) | `temperature` | Float | Suhu ruangan dalam Celsius (°C) [-10.0 s/d 100.0] |
| Kelembaban (DHT22) | `humidity` | Float | Kelembaban relatif dalam %RH [0.0 s/d 100.0] |
| Accelerometer (MPU6050) | `accel_x`, `accel_y`, `accel_z` | Float | Percepatan gerak sudut per axis (m/s²) |
| Getaran (MPU6050) | `vibration_rms` | Float | Nilai RMS getaran fisik (m/s²) [>= 0] |
| Uap Gas (MQ-135) | `flux_ppm` | Float | Kadar uap gas terdeteksi (ppm) [>= 0] |
| Kualitas Udara (MQ-135) | `flux_aqi` | Integer | Indeks kualitas udara (AQI) [0 s/d 500] |
| Kategori VOC (MQ-135) | `voc_level` | String | Kategori tingkat gas: `GOOD`, `MODERATE`, `UNHEALTHY`, `HAZARDOUS` |

---

## Hasil Eksperimen Spark Scaling

Eksperimen membandingkan execution time Spark batch job pada arsitektur baru (ARCH-001) dengan berbagai jumlah worker. Job mencakup: read Parquet dari S3, aggregasi per device, anomaly detection, dan distributed JDBC write.

### Dataset

- **Records:** 1.000.000
- **Format:** Parquet di S3 (~64 MB)
- **Devices:** 20
- **Time span:** 30 hari

### Hasil

| Skenario        | Workers | Samples | Min      | Avg       | Max       |
|-----------------|---------|---------|----------|-----------|-----------|
| Local mode      | 0       | 5       | 27.45 s  | 28.56 s   | 30.33 s   |
| 1 worker        | 1       | 4       | 42.30 s  | 42.47 s   | 42.63 s   |
| 2 worker        | 2       | 1*      | 44.13 s  | 44.13 s   | 44.13 s   |

> *) 2 worker memiliki variance ekstrem — beberapa run sukses (~44s), sebagian lain stuck > 5 menit hingga di-batalkan. Hasil ini sendiri menjadi temuan eksperimen.

### Analisis

Pada skala 1M records dengan worker constraint (t3.small, 2GB RAM, 30GB EBS), distributed Spark menunjukkan **negative scaling**:

- Local mode (28s) lebih cepat dari mode dengan worker (42-44s).
- Penambahan worker dari 1 ke 2 tidak memberikan speedup, justru menambah variance.
- Run dengan 3 worker konsisten gagal (disk space / executor heartbeat timeout).

Penyebab fundamental:

1. **Network & coordination overhead** — Spark butuh distribute jars (~250MB), shuffle data antar executor, koordinasi master-worker. Untuk dataset 64MB, biaya ini > benefit parallelism.
2. **JDBC write contention** — `coalesce(2)` + multiple worker = paralel write ke 1 DB primary.
3. **Hardware constraint** — t3.small (2GB RAM) tidak memberikan ruang yang cukup untuk caching + shuffle, memaksa spill ke disk.

Hasil ini konsisten dengan **Amdahl's Law** — pada serial portion yang signifikan (driver coordination, DB write, S3 I/O), maximum speedup terbatas terlepas dari jumlah worker. Distributed computing baru memberikan ROI positif pada dataset skala GB-TB dan worker dengan resource lebih besar (r5.xlarge+).

### Eksperimen dengan Data Real (simulator)

Benchmark menggunakan data aktual dari simulator IoT yang berjalan di production (bukan synthetic). Data di-export dari TimescaleDB → Parquet → S3, lalu dianalisis oleh Spark.

**Dataset:** 5.388 records, 3 device, window 1 jam (data terbaru hasil ingestion real-time)

| Skenario        | Workers | Samples | Min      | Avg       | Max       |
|-----------------|---------|---------|----------|-----------|-----------|
| Local mode      | 0       | 3       | 13.65 s  | 13.90 s   | 14.10 s   |
| 1 worker        | 1       | 1       | 22.15 s  | 22.15 s   | 22.15 s   |
| 2 worker        | 2       | 3       | 21.09 s  | 22.99 s   | 25.11 s   |
| 3 worker        | 3       | 4       | 22.36 s  | 25.07 s   | 27.58 s   |
| 4 worker        | 4       | 3       | 21.92 s  | 24.32 s   | 25.74 s   |
| 5 worker        | 5       | 2       | 21.67 s  | 22.19 s   | 22.72 s   |

**Temuan:**

- Local mode konsisten paling cepat (~14s) — semua compute terjadi in-process tanpa network.
- Semua skenario distributed (1-5 worker) menunjukkan **overhead konstan ~8-11 detik** dibanding local.
- Penambahan worker dari 1 ke 5 **tidak memberikan speedup** — waktu tetap ~22-25s.
- Overhead tersebut berasal dari: executor launch, jar distribution, network roundtrip, JDBC connection setup.
- Compute actual (groupBy + anomaly detection) untuk 5K records < 1 detik — terlalu kecil untuk di-paralelkan.

Semua run berhasil tanpa error — menunjukkan bahwa **arsitektur distributed sudah stabil**, hanya belum memberikan performance benefit pada skala ini.

### Eksperimen Sebelumnya (arsitektur lama)

Pada arsitektur sebelumnya (DB primary di app node), benchmark dengan 36.057 records menunjukkan diminishing returns dengan speedup terbatas (1.06x - 1.21x). Lihat git history untuk detail.

### Catatan Eksperimen

- Selama proses tuning, ditemukan beberapa issue infrastructure yang berpengaruh signifikan: IMDSv2 incompatibility dengan AWS SDK lama, worker tanpa public IP tidak bisa akses S3, IAM `PassRole` permission, EBS undersized untuk Spark shuffle. Detail di `docs/runbook-spark-setup.md`.
- Hasil 1 worker sangat konsisten (variance < 1s) menunjukkan setup stabil. Variance hanya muncul pada skenario multi-worker.

---

## Struktur Folder

```text
iot-bigdata-project/
├── backend/                    # FastAPI app + MQTT consumer
│   └── app/
│       ├── main.py             # Entry point, startup/shutdown
│       ├── db.py               # Connection pool ke TimescaleDB
│       ├── models/             # Pydantic schema (validasi payload)
│       ├── routes/             # HTTP endpoint
│       └── mqtt/               # MQTT consumer (subscribe & proses pesan)
├── simulator/                  # Script simulasi device IoT
├── spark-jobs/                 # PySpark batch analytics
│   ├── export_to_parquet.py    # Export DB Standby → Parquet → S3
│   ├── batch_analytics.py      # Spark job: S3 → analytics → DB Primary
│   ├── run_hourly_pipeline.sh  # Orkestrator utama pipeline jam-an
│   ├── generate_bulk_data.py   # Generate synthetic dataset untuk benchmark
│   ├── run_with_worker.sh      # Automasi ephemeral worker (opsional)
│   └── data/parquet/           # Temporary Parquet (tidak di-commit)
├── benchmarks/                 # Suite benchmark (ingestion, health, idempotency)
│   ├── run_comparison.sh       # Script pembanding benchmark dinamis
│   └── compare_results.py      # Visualisasi laporan perbandingan benchmark
├── db/
│   └── init.sql                # Schema TimescaleDB (tabel + hypertable + retention)
├── infra/
│   ├── docker-compose.yml      # Mosquitto + Grafana + Prometheus di applayer-1
│   ├── .env.example
│   ├── generate_mqtt_passwd.sh # Helper generate Mosquitto password
│   ├── scripts/                # Provisioning scripts untuk DB nodes
│   │   ├── provision-db-primary.sh
│   │   └── provision-db-replica.sh
│   ├── mosquitto/
│   │   └── mosquitto.conf
│   ├── prometheus/             # Konfigurasi Prometheus Server
│   │   └── prometheus.yml
│   ├── alloy/                  # Konfigurasi Grafana Alloy push-agent
│   │   └── config.alloy
│   └── systemd/                # Berkas unit systemd untuk cloud deployment
│       ├── certbot-renew.service
│       ├── certbot-renew.timer
│       ├── iot-backend.service
│       ├── iot-analytics.service
│       └── iot-analytics.timer
├── grafana/
│   └── provisioning/
│       ├── datasources/        # TimescaleDB & Prometheus datasource (env-based)
│       ├── dashboards/         # Dashboard IoT monitoring & Server monitor
│       └── alerting/           # Alert rules + contact points (Telegram Alerting)
├── docs/
│   ├── ARCH-001-refactor-infra-topology.md   # Dokumen arsitektur topologi DB terpisah
│   ├── aws-infrastructure.md                 # Konfigurasi VPC, SG, IAM AWS
│   ├── runbook-db-setup.md                   # Setup PostgreSQL + TimescaleDB + Replication
│   └── runbook-spark-setup.md                # Setup Spark + benchmarking & systemd automation
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

* **Menjalankan Pipeline secara Manual (Ad-hoc):**
  ```bash
  cd spark-jobs && source .venv/bin/activate

  # Orkestrasikan ekspor dan analisis secara berurutan secara lokal
  chmod +x run_hourly_pipeline.sh
  ./run_hourly_pipeline.sh
  ```

* **Menjalankan Spark job dengan Ephemeral Worker (AWS CLI):**
  ```bash
  cd spark-jobs && source .venv/bin/activate
  ./run_with_worker.sh s3://iot-bigdata-datalake-kagebyo/raw/<file>.parquet 2
  ```

* **Deploy Systemd Timer (Otomatis per Jam di Cloud AWS):**
  Salin file unit systemd ke folder sistem dan aktifkan timernya:
  ```bash
  sudo cp infra/systemd/iot-analytics.* /etc/systemd/system/
  sudo systemctl daemon-reload
  sudo systemctl enable --now iot-analytics.timer
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
| 7     | Evaluasi & analisis hasil scaling               | ✅ Selesai  |
| 8     | Refactor topology: separate DB layer (ARCH-001) | ✅ Selesai  |
| 9     | Failover simulation (manual primary failover)   | ✅ Selesai  |
| 10    | Automasi Pipeline Jam-an & Setup Monitoring     | ✅ Selesai  |
| 11    | Security hardening: private subnet + VPC Endpoint | ✅ Selesai  |

## Roadmap & Future Enhancements

Meskipun sistem V1 ini sudah memungkinkan untuk diterapkan di lingkungan produksi, ada beberapa *upgrade* arsitektur dan operasional yang bisa diimplementasikan ke depannya untuk mencapai standar skala *Enterprise*:

1. **Infrastructure as Code (IaC) menggunakan Terraform** (✅ **Sudah Diimplementasikan untuk Staging**)
   - **Tujuan:** Mendeskripsikan spesifikasi seluruh jaringan dan *server* AWS (VPC, EC2, S3, Endpoint) ke dalam *file* `.tf`.
   - **Status:** File konfigurasi siap pakai terletak di [infra/terraform/](file:///home/cheshire/iot-bigdata-project/infra/terraform/). Lihat panduan lengkapnya di [Terraform README](file:///home/cheshire/iot-bigdata-project/infra/terraform/README.md).
   - **Keuntungan:** Memungkinkan replikasi lingkungan (*Staging* ke *Production*) dengan sekali jalan (`terraform apply`), serta menjadi *backup plan* yang sempurna (*disaster recovery*) tanpa harus menyentuh AWS Console lagi.

2. **CI/CD Pipeline menggunakan GitHub Actions** (✅ **Sudah Diimplementasikan untuk Staging**)
   - **Tujuan:** Mengotomatiskan alur *deployment* jika ada perubahan fitur di repositori.
   - **Status:** Pipeline otomatis dikonfigurasi pada [.github/workflows/deploy-staging.yml](file:///home/cheshire/iot-bigdata-project/.github/workflows/deploy-staging.yml) untuk otomatisasi deploy ke *Staging applayer-1* setiap kali ada push ke branch `staging`.
   - **Keuntungan:** Tidak perlu lagi *login* SSH manual ke *server* hanya untuk `git pull` dan me-*restart service*. *Pipeline* akan mengeksekusinya secara aman, konsisten, dan bebas dari *human error*.

3. **Real-Time Streaming Analytics (Spark Structured Streaming)**
   - **Tujuan:** Mengevolusi Apache Spark dari pemrosesan *Batch* (setiap 1 jam) menjadi pemrosesan *Streaming* yang membaca data langsung dari *Message Broker* (seperti integrasi MQTT ke Kafka).
   - **Keuntungan:** Menekan latensi *anomaly detection* secara drastis, dari jeda 1 jam menjadi hitungan detik (*real-time*). Sangat krusial untuk peringatan bahaya seperti terdeteksinya kadar *HAZARDOUS VOC Level*.

---

## Catatan

- `.env` tidak di-commit ke git. Gunakan `.env.example` sebagai acuan.
- `grafana/provisioning/alerting/contact-points.yaml` di-commit secara aman ke git karena kredensialnya dibaca dinamis dari file `.env`.
- `infra/mosquitto/passwd` tidak di-commit (berisi hashed password). Generate ulang via `mosquitto_passwd`.
- `db/init.sql` di datalayer-1 dijalankan sekali via provisioning script. Lihat `docs/runbook-db-setup.md`.
- `spark-jobs/data/` tidak di-commit ke git.
- Spark job dari applayer-1 selalu write ke DB Primary (datalayer-1), standby PostgreSQL bersifat read-only.
- S3 access menggunakan IAM Role, tidak ada credentials yang disimpan di kode. Spark Worker di private subnet mengakses S3 melalui VPC Gateway Endpoint (gratis).
- Worker node bersifat ephemeral — di-launch otomatis di private subnet saat job, di-terminate setelah selesai. (Opsional untuk scaling data masif di masa depan. Default saat ini menggunakan mode `local[*]` jam-an di applayer-1).
- Custom AMI worker (Amazon Linux 2023 + Java 21 + Spark 3.5.8).
- Database nodes berada di private subnet (`10.0.2.0/24`) tanpa akses internet. Akses SSH melalui applayer-1 sebagai Bastion Host.
- Detail dokumentasi setup di `docs/runbook-db-setup.md` dan `docs/runbook-spark-setup.md`.
- Detail konfigurasi infrastruktur AWS (VPC, SG, IAM, VPC Endpoint) di `docs/aws-infrastructure.md`.