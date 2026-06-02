# Benchmark & Comparison Suite

Membandingkan performa antara branch `main` (original) dan branch pembanding / workspace saat ini.

## Yang Diukur

| Benchmark | Apa yang diuji |
|-----------|---------------|
| `bench_ingestion.py` | Throughput ingestion MQTT → DB (msg/sec) |
| `bench_health.py` | Kedalaman health check endpoint |
| `bench_spark_idempotency.py` | Apakah Spark job aman di-rerun tanpa duplikat |

## Cara Menjalankan

```bash
cd benchmarks
./run_comparison.sh
```

Script ini akan:
1. Start Docker infra (TimescaleDB + Mosquitto)
2. Checkout `main` → jalankan semua benchmark → simpan hasil
3. Checkout branch aktif asal / target → jalankan semua benchmark → simpan hasil
4. Generate comparison report
5. Cleanup (stop infra, restore branch)

## Prerequisites

- Docker & Docker Compose
- Python 3.12+ dengan venv sudah di-setup:
  - `backend/.venv` (FastAPI + dependencies)
  - `spark-jobs/.venv` (PySpark + dependencies)
- `infra/.env` sudah dikonfigurasi
- Tidak ada service lain yang pakai port 5432, 1883, 8000

## Hasil

Setelah selesai, hasil ada di:
- `results/*.json` — raw data per benchmark
- `results/COMPARISON_REPORT.md` — tabel perbandingan lengkap

## Menjalankan Benchmark Individual

```bash
# Ingestion saja
source ../backend/.venv/bin/activate
python bench_ingestion.py --scale realistic --output results/test.json

# Health check saja
python bench_health.py --output results/test_health.json

# Spark idempotency saja (perlu spark-jobs/.venv)
source ../spark-jobs/.venv/bin/activate
python bench_spark_idempotency.py --output results/test_spark.json
```

## Interpretasi Hasil

- **Throughput (stress)**: Angka ini menunjukkan perbedaan nyata antara single-insert vs batch-insert. Expect 3-10x improvement pada stress load.
- **Throughput (realistic)**: Pada load rendah, perbedaan mungkin kecil karena bottleneck bukan di DB insert.
- **Health check**: `main` hanya return `{"status":"ok"}`, improved return `{"status":"ok","db":true,"mqtt":true}`.
- **Spark idempotency**: `main` akan menunjukkan duplikat setelah re-run, improved tidak.

## Catatan

- Benchmark menggunakan device_id prefix `bench_` — semua data test dibersihkan setelah selesai.
- Mosquitto berjalan dengan `allow_anonymous true` selama benchmark (menggunakan config dari main branch).
- Hasil bersifat environment-specific — angka absolut berbeda antara lokal dan AWS, tapi rasio improvement konsisten.
