# ============================================================
# infra/terraform/security.tf
# Security Groups — Firewall rules per layer
# Uses standalone aws_security_group_rule resources to prevent
# dependency cycles (circular dependency) in Terraform.
# ============================================================

# ---- 1. Applayer Security Group ----
# For: applayer (FastAPI, MQTT, Grafana, Spark Master)
resource "aws_security_group" "applayer" {
  name        = "${var.project_name}-${var.environment}-applayer-sg"
  description = "SG for app layer - Bastion Host, MQTT, Grafana"
  vpc_id      = aws_vpc.main.id

  # Outbound: all traffic allowed
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-applayer-sg"
  }
}

# ---- 2. Datalayer Security Group ----
# For: datalayer-1 (DB Primary), datalayer-2 (DB Replica)
resource "aws_security_group" "datalayer" {
  name        = "${var.project_name}-${var.environment}-datalayer-sg"
  description = "SG for database layer - PostgreSQL + replication"
  vpc_id      = aws_vpc.main.id

  # Outbound: all traffic allowed
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-datalayer-sg"
  }
}

# ---- 3. Worker Security Group ----
# For: Ephemeral Spark Worker (private subnet, no internet)
resource "aws_security_group" "worker" {
  name        = "${var.project_name}-${var.environment}-worker-sg"
  description = "SG for ephemeral Spark worker"
  vpc_id      = aws_vpc.main.id

  # Outbound: all traffic allowed (S3 via VPC Endpoint)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-worker-sg"
  }
}

# ============================================================
# INBOUND RULES (Standalone resources to avoid circular dependencies)
# ============================================================

# ---- Rules for Applayer SG ----
resource "aws_security_group_rule" "applayer_mqtt" {
  type              = "ingress"
  description       = "MQTT TLS from external IoT devices (Public)"
  from_port         = 8883
  to_port           = 8883
  protocol          = "tcp"
  security_group_id = aws_security_group.applayer.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "applayer_from_datalayer_prometheus" {
  type                     = "ingress"
  description              = "Prometheus metrics from datalayer (Grafana Alloy push)"
  from_port                = 9090
  to_port                  = 9090
  protocol                 = "tcp"
  security_group_id        = aws_security_group.applayer.id
  source_security_group_id = aws_security_group.datalayer.id
}

resource "aws_security_group_rule" "applayer_from_worker_spark" {
  type                     = "ingress"
  description              = "Spark RPC from worker"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = aws_security_group.applayer.id
  source_security_group_id = aws_security_group.worker.id
}

resource "aws_security_group_rule" "applayer_from_datalayer_etcd" {
  type                     = "ingress"
  description              = "etcd DCS client request from datalayer"
  from_port                = 2379
  to_port                  = 2379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.applayer.id
  source_security_group_id = aws_security_group.datalayer.id
}

# ---- Rules for Datalayer SG ----
resource "aws_security_group_rule" "datalayer_from_applayer_postgres" {
  type                     = "ingress"
  description              = "PostgreSQL from applayer (FastAPI/Grafana)"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.datalayer.id
  source_security_group_id = aws_security_group.applayer.id
}

resource "aws_security_group_rule" "datalayer_from_applayer_ssh" {
  type                     = "ingress"
  description              = "SSH from Bastion (applayer)"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  security_group_id        = aws_security_group.datalayer.id
  source_security_group_id = aws_security_group.applayer.id
}

resource "aws_security_group_rule" "datalayer_from_worker_postgres" {
  type                     = "ingress"
  description              = "PostgreSQL from Spark worker"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.datalayer.id
  source_security_group_id = aws_security_group.worker.id
}

resource "aws_security_group_rule" "datalayer_self_postgres" {
  type                     = "ingress"
  description              = "Streaming replication between DB nodes"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.datalayer.id
  source_security_group_id = aws_security_group.datalayer.id
}

resource "aws_security_group_rule" "datalayer_from_applayer_patroni" {
  type                     = "ingress"
  description              = "Patroni REST API / HAProxy Health checks"
  from_port                = 8008
  to_port                  = 8008
  protocol                 = "tcp"
  security_group_id        = aws_security_group.datalayer.id
  source_security_group_id = aws_security_group.applayer.id
}

resource "aws_security_group_rule" "datalayer_self_patroni" {
  type                     = "ingress"
  description              = "Patroni REST API inter-node communication"
  from_port                = 8008
  to_port                  = 8008
  protocol                 = "tcp"
  security_group_id        = aws_security_group.datalayer.id
  source_security_group_id = aws_security_group.datalayer.id
}


# ---- Rules for Worker SG ----
resource "aws_security_group_rule" "worker_from_applayer" {
  type                     = "ingress"
  description              = "Allow Spark control and block transfer from applayer"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = aws_security_group.worker.id
  source_security_group_id = aws_security_group.applayer.id
}

resource "aws_security_group_rule" "worker_self" {
  type                     = "ingress"
  description              = "Allow block transfer and shuffle between workers"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = aws_security_group.worker.id
  source_security_group_id = aws_security_group.worker.id
}
