#!/bin/bash
# ============================================================
# benchmarks/run_comparison.sh
# One-command benchmark comparison between main and improved branches.
#
# Usage:
#   cd benchmarks && ./run_comparison.sh
#
# Prerequisites:
#   - Docker & Docker Compose
#   - Python 3.12+ with backend/.venv and spark-jobs/.venv set up
#   - infra/.env configured
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
export PROJECT_ROOT
RESULTS_DIR="$SCRIPT_DIR/results"
BACKEND_PID=""
ORIGINAL_BRANCH=""
STASHED=false
BENCH_TMP=""

# ============================================================
# Cleanup trap
# ============================================================
cleanup() {
    echo ""
    echo "[CLEANUP] Cleaning up..."

    # Kill backend if running
    if [ -n "$BACKEND_PID" ] && kill -0 "$BACKEND_PID" 2>/dev/null; then
        kill "$BACKEND_PID" 2>/dev/null || true
        wait "$BACKEND_PID" 2>/dev/null || true
    fi

    # Stop infra
    cd "$PROJECT_ROOT/infra"
    docker compose down 2>/dev/null || true

    # Restore branch
    cd "$PROJECT_ROOT"
    if [ -n "$ORIGINAL_BRANCH" ]; then
        git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true
    fi
    if [ "$STASHED" = true ]; then
        git stash pop 2>/dev/null || true
    fi

    # Remove temp dir
    if [ -n "$BENCH_TMP" ] && [ -d "$BENCH_TMP" ]; then
        rm -rf "$BENCH_TMP"
    fi

    echo "[CLEANUP] Done."
}
trap cleanup EXIT

# ============================================================
# Helper functions
# ============================================================
wait_for_backend() {
    echo "  Waiting for backend..."
    for i in $(seq 1 30); do
        if curl -s http://localhost:8000/health > /dev/null 2>&1; then
            echo "  Backend ready."
            return 0
        fi
        sleep 1
    done
    echo "  ERROR: Backend did not start within 30s"
    return 1
}

start_backend() {
    cd "$PROJECT_ROOT/backend"
    source .venv/bin/activate
    uvicorn app.main:app --host 0.0.0.0 --port 8000 > /dev/null 2>&1 &
    BACKEND_PID=$!
    cd "$SCRIPT_DIR"
    wait_for_backend
}

stop_backend() {
    if [ -n "$BACKEND_PID" ] && kill -0 "$BACKEND_PID" 2>/dev/null; then
        kill "$BACKEND_PID" 2>/dev/null || true
        wait "$BACKEND_PID" 2>/dev/null || true
        BACKEND_PID=""
    fi
    sleep 1
}

run_bench_ingestion() {
    local scale=$1
    local output=$2
    cd "$SCRIPT_DIR"
    source "$PROJECT_ROOT/backend/.venv/bin/activate"
    python bench_ingestion.py --scale "$scale" --output "$output"
}

run_bench_health() {
    local output=$1
    cd "$SCRIPT_DIR"
    source "$PROJECT_ROOT/backend/.venv/bin/activate"
    python bench_health.py --output "$output"
}

run_bench_spark() {
    local output=$1
    cd "$SCRIPT_DIR"
    source "$PROJECT_ROOT/spark-jobs/.venv/bin/activate"
    python bench_spark_idempotency.py --output "$output"
}

# ============================================================
# Main
# ============================================================
echo "============================================"
echo "  BENCHMARK COMPARISON SUITE"
echo "  Project: iot-bigdata-project"
echo "============================================"
echo ""

# Prepare
cd "$PROJECT_ROOT"
ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
mkdir -p "$RESULTS_DIR"

# Copy benchmark scripts to temp dir so they survive branch switches
BENCH_TMP=$(mktemp -d)
cp "$SCRIPT_DIR"/bench_*.py "$BENCH_TMP/"
cp "$SCRIPT_DIR"/compare_results.py "$BENCH_TMP/"
SCRIPT_DIR="$BENCH_TMP"
# Keep results in original location
mkdir -p "$RESULTS_DIR"

# Stash uncommitted changes if any
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    echo "[PREP] Stashing uncommitted changes..."
    git stash push -m "benchmark-auto-stash"
    STASHED=true
fi

# ============================================================
# Step 1: Start infrastructure (on main for anonymous MQTT)
# ============================================================
echo ""
echo "[STEP 1] Starting infrastructure..."
git checkout main
cd "$PROJECT_ROOT/infra"
docker compose up -d
echo "  Waiting for DB to be healthy..."
sleep 5
# Wait for DB
for i in $(seq 1 30); do
    if docker exec iot_timescaledb pg_isready -U "$(grep POSTGRES_USER "$PROJECT_ROOT/infra/.env" | cut -d= -f2)" > /dev/null 2>&1; then
        echo "  DB ready."
        break
    fi
    sleep 1
done

# ============================================================
# Step 2: Benchmark MAIN branch
# ============================================================
echo ""
echo "============================================"
echo "  BENCHMARKING: main branch"
echo "============================================"

git checkout main
start_backend

run_bench_ingestion "realistic" "$RESULTS_DIR/main_realistic.json"
run_bench_ingestion "stress" "$RESULTS_DIR/main_stress.json"
run_bench_health "$RESULTS_DIR/main_health.json"
run_bench_spark "$RESULTS_DIR/main_spark.json"

stop_backend

# ============================================================
# Step 3: Benchmark IMPROVED branch
# ============================================================
echo ""
echo "============================================"
echo "  BENCHMARKING: feature/agent-improvements"
echo "============================================"

git checkout feature/agent-improvements
start_backend

run_bench_ingestion "realistic" "$RESULTS_DIR/improved_realistic.json"
run_bench_ingestion "stress" "$RESULTS_DIR/improved_stress.json"
run_bench_health "$RESULTS_DIR/improved_health.json"
run_bench_spark "$RESULTS_DIR/improved_spark.json"

stop_backend

# ============================================================
# Step 4: Generate comparison report
# ============================================================
echo ""
echo "============================================"
echo "  GENERATING COMPARISON REPORT"
echo "============================================"

cd "$SCRIPT_DIR"
source "$PROJECT_ROOT/backend/.venv/bin/activate"
python compare_results.py

echo ""
echo "============================================"
echo "  BENCHMARK COMPLETE"
echo "  Results: $RESULTS_DIR/"
echo "  Report:  $RESULTS_DIR/COMPARISON_REPORT.md"
echo "============================================"
