"""
docs/diagram.py
Generate the project architecture diagram as a PNG image.

Usage:
    cd docs
    python diagram.py

Output:
    docs/architecture.png
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import EC2
from diagrams.aws.storage import S3
from diagrams.aws.network import VPC
from diagrams.onprem.queue import RabbitMQ
from diagrams.onprem.compute import Server
from diagrams.onprem.database import PostgreSQL
from diagrams.onprem.analytics import Spark
from diagrams.onprem.monitoring import Grafana, Prometheus
from diagrams.onprem.ci import GithubActions
from diagrams.programming.language import Python
from diagrams.generic.device import Tablet


def main():
    graph_attr = {
        "fontsize": "13",
        "bgcolor": "white",
        "pad": "0.5",
        "splines": "ortho",      # Orthogonal (90-degree straight lines) instead of wavy splines
        "nodesep": "0.8",        # Node spacing
        "ranksep": "1.0",        # Layer spacing
        "concentrate": "false",
    }

    node_attr = {
        "fontsize": "11",
        "fontname": "Sans-Serif",
    }

    with Diagram(
        "IoT Big Data: Factory Telemetry & Control Pipeline Architecture",
        filename="architecture",
        outformat="png",
        show=False,
        direction="LR",          # Left-to-Right flow (standard AWS topology format)
        graph_attr=graph_attr,
        node_attr=node_attr,
    ):
        # Edge Layer (Far Left)
        with Cluster("Edge Layer"):
            simulator = Python("IoT Simulator\n(3 Workstations)")
            fan = Tablet("Cooling Fan\n(Actuator)")

        # External Services (Far Right)
        gha = GithubActions("GitHub Actions\nCI/CD")

        # AWS Cloud & VPC Topology
        with Cluster("AWS VPC (ap-southeast-1)"):

            # Public Subnet
            with Cluster("Public Subnet (10.x.1.0/24) - applayer-1 EC2 Host"):
                broker = RabbitMQ("Mosquitto Broker\n(MQTT TLS 8883)")
                api = Server("FastAPI Backend\n(Port 8000)")
                spark = Spark("Apache Spark\n(Local Mode)")
                grafana = Grafana("Grafana\n(Dashboards)")
                prometheus = Prometheus("Prometheus\n(Metrics)")

            # Private Subnet
            with Cluster("Private Subnet (10.x.2.0/24) - Air-Gapped"):
                db_primary = PostgreSQL("datalayer-1\nTimescaleDB Primary")
                db_replica = PostgreSQL("datalayer-2\nTimescaleDB Standby")

        # S3 Data Lake
        s3 = S3("S3 Data Lake\n(Parquet Archival)")

        # --- Inter-Component Connections ---

        # 1. Telemetry Ingestion Flow
        simulator >> Edge(label="MQTT TLS 8883", color="#0d9488") >> broker
        broker >> Edge(label="Payload", color="#0d9488") >> api
        api >> Edge(label="INSERT", color="#2563eb") >> db_primary

        # 2. Closed-Loop Actuator Control
        api >> Edge(label="Fan Cmd", color="#d97706", style="dashed") >> broker
        broker >> Edge(label="Control", color="#d97706", style="dashed") >> simulator
        simulator >> Edge(color="#d97706", style="dashed") >> fan

        # 3. Database Streaming Replication
        db_primary >> Edge(label="Streaming WAL", color="#7c3aed", style="bold") >> db_replica

        # 4. Hourly Spark Batch Analytics Flow
        db_replica >> Edge(label="Read Replica", color="#4b5563", style="dashed") >> spark
        spark >> Edge(label="Export Parquet", color="#1e40af") >> s3
        s3 >> Edge(label="Read Parquet", color="#1e40af", style="dashed") >> spark
        spark >> Edge(label="Write Analytics", color="#dc2626") >> db_primary

        # 5. Monitoring & Observability
        grafana >> Edge(label="SQL Query", color="#4b5563") >> db_primary
        prometheus >> Edge(color="#9ca3af", style="dotted") >> grafana

        # 6. CI/CD Deployment
        gha >> Edge(label="Tailscale VPN", color="#e11d48", style="dashed") >> api


if __name__ == "__main__":
    main()
