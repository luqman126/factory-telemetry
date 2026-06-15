#!/usr/bin/env python3
# ============================================================
# render_alloy_config.py
# Render Grafana Alloy configuration from template based on node role
# OS: Any (Python 3)
# ============================================================
import sys
import os
import argparse

def parse_env(env_path):
    env_vars = {}
    if not os.path.exists(env_path):
        print(f"WARNING: Env file {env_path} not found.")
        return env_vars
    with open(env_path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            k, v = line.split('=', 1)
            # Remove quotes
            v = v.strip('"\'')
            env_vars[k.strip()] = v
    return env_vars

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--role', required=True, choices=['applayer', 'datalayer-1', 'datalayer-2'])
    parser.add_argument('--prometheus-ip', required=True)
    parser.add_argument('--template', required=True)
    parser.add_argument('--env', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()

    env_vars = parse_env(args.env)

    # Validate required env vars for database nodes
    required_keys = ['POSTGRES_USER', 'POSTGRES_PASSWORD', 'POSTGRES_DB']
    if args.role in ['datalayer-1', 'datalayer-2']:
        missing = [k for k in required_keys if k not in env_vars or not env_vars[k]]
        if missing:
            print(f"ERROR: Missing required env vars for {args.role}: {', '.join(missing)}", file=sys.stderr)
            print("Ensure fetch-secrets.sh has been run first.", file=sys.stderr)
            sys.exit(1)

    db_user = env_vars.get('POSTGRES_USER', '')
    db_pass = env_vars.get('POSTGRES_PASSWORD', '')
    db_name = env_vars.get('POSTGRES_DB', '')

    with open(args.template, 'r') as f:
        content = f.read()

    # Replace Prometheus IP and Instance Name
    content = content.replace('#PROMETHEUS_IP#', args.prometheus_ip)
    content = content.replace('#INSTANCE_NAME#', args.role)

    # Replace Postgres blocks
    if args.role in ['datalayer-1', 'datalayer-2']:
        exporter_block = f"""
// Integrasi Exporter Postgres pada database
prometheus.exporter.postgres "postgres_metrics" {{
  data_source_names = ["postgresql://{db_user}:{db_pass}@localhost:5432/{db_name}?sslmode=disable"]
}}
"""
        scrape_block = """
// Menarik data metrik database Postgres
prometheus.scrape "scrape_postgres" {
  targets    = prometheus.exporter.postgres.postgres_metrics.targets
  forward_to = [prometheus.relabel.rename_instance.receiver]
}
"""
        content = content.replace('#POSTGRES_EXPORTER_BLOCK#', exporter_block)
        content = content.replace('#POSTGRES_SCRAPE_BLOCK#', scrape_block)
    else:
        content = content.replace('#POSTGRES_EXPORTER_BLOCK#', '')
        content = content.replace('#POSTGRES_SCRAPE_BLOCK#', '')

    with open(args.output, 'w') as f:
        f.write(content)

    print(f"SUCCESS: Rendered Alloy config for {args.role} to {args.output}")

if __name__ == '__main__':
    main()
