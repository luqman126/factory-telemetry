"""
benchmarks/compare_results.py
Read benchmark results from both branches and generate comparison report.

Usage:
    python compare_results.py
"""

import json
import os
from datetime import datetime, timezone
from pathlib import Path

_project_root = Path(os.environ.get("PROJECT_ROOT", "")).resolve()
if not (_project_root / ".git").exists():
    _project_root = Path(__file__).resolve().parents[1]
RESULTS_DIR = _project_root / "benchmarks" / "results"


def load_json(filename):
    path = RESULTS_DIR / filename
    if path.exists():
        return json.loads(path.read_text())
    return None


def pct_change(old, new):
    if old == 0:
        return "N/A"
    change = ((new - old) / old) * 100
    sign = "+" if change > 0 else ""
    return f"{sign}{change:.1f}%"


def generate_report():
    # Load all results
    main_realistic = load_json("main_realistic.json")
    main_stress = load_json("main_stress.json")
    main_health = load_json("main_health.json")
    main_spark = load_json("main_spark.json")

    improved_realistic = load_json("improved_realistic.json")
    improved_stress = load_json("improved_stress.json")
    improved_health = load_json("improved_health.json")
    improved_spark = load_json("improved_spark.json")

    # Build report
    lines = []
    lines.append("# Benchmark Comparison Report")
    lines.append("")
    lines.append(f"Generated: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}")
    lines.append("")

    # Metadata
    lines.append("## Environment")
    lines.append("")
    if main_realistic:
        lines.append(f"- **main** branch commit: `{main_realistic.get('git_commit', 'N/A')}`")
    if improved_realistic:
        lines.append(f"- **feature/agent-improvements** commit: `{improved_realistic.get('git_commit', 'N/A')}`")
    lines.append("")

    # Ingestion throughput
    lines.append("## Ingestion Throughput")
    lines.append("")
    lines.append("| Metric | main | improved | Change |")
    lines.append("|--------|------|----------|--------|")

    if main_realistic and improved_realistic:
        m = main_realistic["throughput_msg_per_sec"]
        i = improved_realistic["throughput_msg_per_sec"]
        lines.append(f"| Throughput (realistic: 3 devices, 100 msgs) | {m} msg/s | {i} msg/s | {pct_change(m, i)} |")
        lines.append(f"| Total time (realistic) | {main_realistic['total_time_sec']}s | {improved_realistic['total_time_sec']}s | {pct_change(main_realistic['total_time_sec'], improved_realistic['total_time_sec'])} |")
        lines.append(f"| Messages confirmed (realistic) | {main_realistic['messages_confirmed']}/{main_realistic['messages_sent']} | {improved_realistic['messages_confirmed']}/{improved_realistic['messages_sent']} | — |")

    if main_stress and improved_stress:
        m = main_stress["throughput_msg_per_sec"]
        i = improved_stress["throughput_msg_per_sec"]
        lines.append(f"| Throughput (stress: 50 devices, 2000 msgs) | {m} msg/s | {i} msg/s | {pct_change(m, i)} |")
        lines.append(f"| Total time (stress) | {main_stress['total_time_sec']}s | {improved_stress['total_time_sec']}s | {pct_change(main_stress['total_time_sec'], improved_stress['total_time_sec'])} |")
        lines.append(f"| Messages confirmed (stress) | {main_stress['messages_confirmed']}/{main_stress['messages_sent']} | {improved_stress['messages_confirmed']}/{improved_stress['messages_sent']} | — |")

    lines.append("")

    # Health check
    lines.append("## Health Check Depth")
    lines.append("")
    lines.append("| Metric | main | improved |")
    lines.append("|--------|------|----------|")

    if main_health and improved_health:
        lines.append(f"| Response fields | `{main_health['response_fields']}` | `{improved_health['response_fields']}` |")
        lines.append(f"| DB connectivity check | {'✓' if main_health['has_db_check'] else '✗'} | {'✓' if improved_health['has_db_check'] else '✗'} |")
        lines.append(f"| MQTT connectivity check | {'✓' if main_health['has_mqtt_check'] else '✗'} | {'✓' if improved_health['has_mqtt_check'] else '✗'} |")
        lines.append(f"| Avg response time | {main_health['avg_response_ms']}ms | {improved_health['avg_response_ms']}ms |")

    lines.append("")

    # Spark idempotency
    lines.append("## Spark Job Idempotency")
    lines.append("")
    lines.append("| Metric | main | improved |")
    lines.append("|--------|------|----------|")

    if main_spark and improved_spark:
        lines.append(f"| Run 1 analytics rows | {main_spark['run1_analytics_count']} | {improved_spark['run1_analytics_count']} |")
        lines.append(f"| Run 2 analytics rows | {main_spark['run2_analytics_count']} | {improved_spark['run2_analytics_count']} |")
        lines.append(f"| Duplicates after re-run | {'Yes ✗' if main_spark['duplicates_found'] else 'No ✓'} | {'Yes ✗' if improved_spark['duplicates_found'] else 'No ✓'} |")
        lines.append(f"| Values identical | {'✓' if main_spark['values_match'] else '✗'} | {'✓' if improved_spark['values_match'] else '✗'} |")
        lines.append(f"| DELETE-before-INSERT | {'✓' if main_spark['log_shows_delete'] else '✗'} | {'✓' if improved_spark['log_shows_delete'] else '✗'} |")
        lines.append(f"| **Idempotent** | {'✓' if main_spark.get('idempotent') else '**✗ NOT SAFE**'} | {'✓' if improved_spark.get('idempotent') else '✗'} |")
    elif improved_spark:
        lines.append(f"| Run 1 analytics rows | — | {improved_spark['run1_analytics_count']} |")
        lines.append(f"| Run 2 analytics rows | — | {improved_spark['run2_analytics_count']} |")
        lines.append(f"| Duplicates after re-run | — | {'Yes ✗' if improved_spark['duplicates_found'] else 'No ✓'} |")
        lines.append(f"| **Idempotent** | — | {'✓' if improved_spark.get('idempotent') else '✗'} |")

    lines.append("")

    # Summary
    lines.append("## Summary")
    lines.append("")
    improvements = []
    if main_stress and improved_stress:
        m = main_stress["throughput_msg_per_sec"]
        i = improved_stress["throughput_msg_per_sec"]
        if i > m:
            improvements.append(f"- **Ingestion throughput** improved by {pct_change(m, i)} under stress load (buffered batch insert)")
    if improved_health and improved_health["has_db_check"]:
        improvements.append("- **Health check** now verifies DB and MQTT connectivity (deep check)")
    if improved_spark and improved_spark.get("idempotent"):
        improvements.append("- **Spark jobs** are now idempotent — safe to re-run without duplicates")

    if improvements:
        for imp in improvements:
            lines.append(imp)
    else:
        lines.append("- No significant improvements detected (check if benchmarks ran correctly)")

    lines.append("")

    report = "\n".join(lines)

    # Print to console
    print(f"\n{'='*60}")
    print(report)
    print(f"{'='*60}")

    # Save to file
    report_path = RESULTS_DIR / "COMPARISON_REPORT.md"
    report_path.write_text(report)
    print(f"\nReport saved to: {report_path}")


if __name__ == "__main__":
    generate_report()
