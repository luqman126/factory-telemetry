#!/bin/bash
# ============================================================
# spark-jobs/run_with_worker.sh
# Ephemeral Spark worker orchestration:
#   1. Launch EC2 worker instances
#   2. Wait until instances are running
#   3. Start Spark worker daemon
#   4. Submit Spark job
#   5. Terminate EC2 worker instances
#
# Usage:
#   ./run_with_worker.sh <s3_parquet_uri> <worker_count>
#
# Example:
#   ./run_with_worker.sh s3://iot-bigdata-datalake-kagebyo/raw/sensor_xxx.parquet 1
# ============================================================

set -e  # Exit on error

# ============================================================
# Cleanup trap - ensures workers are terminated even if the script fails
# ============================================================
INSTANCE_IDS=()
STARTED_MASTER="false"

cleanup() {
    if [ ${#INSTANCE_IDS[@]} -gt 0 ]; then
        echo ""
        echo "[CLEANUP] Terminating ${#INSTANCE_IDS[@]} worker(s)..."
        aws ec2 terminate-instances \
            --region "$REGION" \
            --instance-ids "${INSTANCE_IDS[@]}" \
            --query 'TerminatingInstances[*].{ID:InstanceId,State:CurrentState.Name}' \
            --output table
    fi
    if [ "$STARTED_MASTER" = "true" ]; then
        echo ""
        echo "[CLEANUP] Stopping Spark Master..."
        $SPARK_HOME/sbin/stop-master.sh
    fi
}
trap cleanup EXIT

# ============================================================
# Load configuration from .env
# ============================================================
ENV_PATH="$(dirname "$0")/../infra/.env"
if [ ! -f "$ENV_PATH" ]; then
    echo "Error: .env not found at $ENV_PATH"
    exit 1
fi
source "$ENV_PATH"

# ============================================================
# Configuration
# ============================================================
REGION="ap-southeast-1"
AMI_ID="ami-03256949a823ccf8b"
INSTANCE_TYPE="t3.small"
SUBNET_ID="$WORKER_SUBNET_ID"
SG_ID="$WORKER_SG_ID"
SPARK_MASTER="$SPARK_MASTER_URL"
SPARK_HOME="/opt/spark"
WORKER_NAME="iot-bigdata-worker-ephemeral"

# ============================================================
# Argument validation
# ============================================================
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <s3_parquet_uri> <worker_count>"
    echo "Example: $0 s3://bucket/raw/file.parquet 1"
    exit 1
fi

S3_URI=$1
WORKER_COUNT=$2

echo "============================================"
echo "IoT Big Data — Ephemeral Worker Script"
echo "S3 URI     : $S3_URI"
echo "Workers    : $WORKER_COUNT"
echo "============================================"

# ============================================================
# User data - inject public key into worker upon launch
# ============================================================
PUB_KEY_PATH="$HOME/.ssh/iot-worker-key.pub"
PRIV_KEY_PATH="$HOME/.ssh/iot-worker-key"

if [ ! -f "$PRIV_KEY_PATH" ]; then
    echo "Worker SSH key pair not found. Generating dynamically..."
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -f "$PRIV_KEY_PATH" -N "" -C "applayer-1-spark"
    chmod 600 "$PRIV_KEY_PATH"
fi
PUB_KEY=$(cat "$PUB_KEY_PATH")

USER_DATA=$(cat <<EOF
#!/bin/bash
echo "$PUB_KEY" >> /home/ec2-user/.ssh/authorized_keys
chmod 600 /home/ec2-user/.ssh/authorized_keys
EOF
)

# Array to store private IPs
WORKER_IPS=()

# ============================================================
# Ensure Spark Master is running
# ============================================================
if ! pgrep -f "org.apache.spark.deploy.master.Master" > /dev/null; then
    echo "Spark Master is not running. Starting Master dynamically..."
    SPARK_LOCAL_IP=$(hostname -I | awk '{print $1}')
    SPARK_DAEMON_MEMORY=256m $SPARK_HOME/sbin/start-master.sh --host "$SPARK_LOCAL_IP"
    STARTED_MASTER="true"
    # Give the Master a few seconds to initialize
    sleep 3
else
    echo "Spark Master is already running."
fi

# ============================================================
# Step 1 — Launch all EC2 workers
# ============================================================
echo ""
echo "[1/5] Launching $WORKER_COUNT EC2 worker(s)..."

for i in $(seq 1 "$WORKER_COUNT"); do
    INSTANCE_ID=$(aws ec2 run-instances \
        --region "$REGION" \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --network-interfaces "AssociatePublicIpAddress=false,DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=$SG_ID" \
        --iam-instance-profile "Name=$WORKER_IAM_PROFILE" \
        --metadata-options "HttpTokens=optional,HttpEndpoint=enabled" \
        --user-data "$USER_DATA" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$WORKER_NAME-$i}]" \
        --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=30,VolumeType=gp3,DeleteOnTermination=true}" \
        --query 'Instances[0].InstanceId' \
        --output text)
    echo "  Worker $i — Instance ID: $INSTANCE_ID"
    INSTANCE_IDS+=("$INSTANCE_ID")
done

# ============================================================
# Step 2 — Wait for all instances to be running
# ============================================================
echo ""
echo "[2/5] Waiting for all instances to be running..."

aws ec2 wait instance-running \
    --region "$REGION" \
    --instance-ids "${INSTANCE_IDS[@]}"

# Fetch private IPs of all workers
for INSTANCE_ID in "${INSTANCE_IDS[@]}"; do
    WORKER_IP=$(aws ec2 describe-instances \
        --region "$REGION" \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' \
        --output text)
    echo "  $INSTANCE_ID → $WORKER_IP"
    WORKER_IPS+=("$WORKER_IP")
done

echo "Waiting for SSH to be ready..."
sleep 30

# ============================================================
# Step 3 — Start Spark worker daemon on all instances
# ============================================================
echo ""
echo "[3/5] Starting Spark workers..."

for WORKER_IP in "${WORKER_IPS[@]}"; do
    ssh -i ~/.ssh/iot-worker-key \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=30 \
        ec2-user@"$WORKER_IP" \
        "SPARK_DAEMON_MEMORY=256m SPARK_LOCAL_DIRS=/opt/spark/work SPARK_LOCAL_IP=$WORKER_IP $SPARK_HOME/sbin/start-worker.sh $SPARK_MASTER"
    echo "  Worker $WORKER_IP started"
done

echo "Waiting for workers to register..."
sleep 15

# ============================================================
# Step 4 — Submit Spark job
# ============================================================
echo ""
echo "[4/5] Submitting Spark job..."

source "$(dirname "$0")/.venv/bin/activate"

# Detect VPC driver IP dynamically
DRIVER_IP=$(hostname -I | awk '{print $1}')
echo "  Driver IP  : $DRIVER_IP"

spark-submit \
    --master "$SPARK_MASTER" \
    --conf spark.driver.host="$DRIVER_IP" \
    --conf spark.driver.bindAddress="$DRIVER_IP" \
    --conf spark.dynamicAllocation.enabled=false \
    --conf spark.executor.extraJavaOptions="-XX:+UseG1GC" \
    --conf spark.local.dir="/opt/spark/work" \
    --executor-memory 768m \
    --driver-memory 512m \
    --packages org.apache.hadoop:hadoop-aws:3.3.4,com.amazonaws:aws-java-sdk-bundle:1.12.261,org.postgresql:postgresql:42.7.4 \
    "$(dirname "$0")/batch_analytics.py" \
    "$S3_URI" \
    "$WORKER_COUNT"

# ============================================================
# Step 5 — Done (cleanup trap will terminate workers automatically)
# ============================================================
echo ""
echo "============================================"
echo "Job completed. Workers will be terminated by the cleanup trap."
echo "============================================"