#!/bin/bash
# ============================================================
# spark-jobs/run_with_worker.sh
# Automasi ephemeral Spark worker:
#   1. Launch EC2 worker
#   2. Tunggu instance running
#   3. Start Spark worker
#   4. Submit Spark job
#   5. Terminate EC2 worker
#
# Usage:
#   ./run_with_worker.sh <s3_parquet_uri> <worker_count>
#
# Contoh:
#   ./run_with_worker.sh s3://iot-bigdata-datalake-kagebyo/raw/sensor_xxx.parquet 1
# ============================================================

set -e  # exit kalau ada command yang gagal

# ============================================================
# Cleanup trap — pastikan worker di-terminate walau script gagal
# ============================================================
INSTANCE_IDS=()

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
}
trap cleanup EXIT

# ============================================================
# Load konfigurasi dari .env
# ============================================================
ENV_PATH="$(dirname "$0")/../infra/.env"
if [ ! -f "$ENV_PATH" ]; then
    echo "Error: .env tidak ditemukan di $ENV_PATH"
    exit 1
fi
source "$ENV_PATH"

# ============================================================
# Konfigurasi
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
# Validasi argumen
# ============================================================
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <s3_parquet_uri> <worker_count>"
    echo "Contoh: $0 s3://bucket/raw/file.parquet 1"
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
# User data — inject public key Node 2 ke worker saat launch
# ============================================================
USER_DATA=$(cat <<'EOF'
#!/bin/bash
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICR+quASFWze7lxSJHLhJrNVy54tHnMD1Yo3a60hty4Z applayer-1-spark" >> /home/ec2-user/.ssh/authorized_keys
chmod 600 /home/ec2-user/.ssh/authorized_keys
EOF
)

# Array untuk simpan IPs
WORKER_IPS=()

# ============================================================
# Step 1 — Launch semua EC2 worker
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
# Step 2 — Tunggu semua instance running
# ============================================================
echo ""
echo "[2/5] Waiting for all instances to be running..."

aws ec2 wait instance-running \
    --region "$REGION" \
    --instance-ids "${INSTANCE_IDS[@]}"

# Ambil private IP semua worker
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
# Step 3 — Start Spark worker di semua instance
# ============================================================
echo ""
echo "[3/5] Starting Spark workers..."

for WORKER_IP in "${WORKER_IPS[@]}"; do
    ssh -i ~/.ssh/iot-worker-key \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=30 \
        ec2-user@"$WORKER_IP" \
        "SPARK_LOCAL_IP=$WORKER_IP $SPARK_HOME/sbin/start-worker.sh $SPARK_MASTER"
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

# Deteksi IP VPC driver secara dinamis
DRIVER_IP=$(hostname -I | awk '{print $1}')
echo "  Driver IP  : $DRIVER_IP"

spark-submit \
    --master "$SPARK_MASTER" \
    --conf spark.driver.host="$DRIVER_IP" \
    --conf spark.driver.bindAddress="$DRIVER_IP" \
    --conf spark.dynamicAllocation.enabled=false \
    --executor-memory 1g \
    --driver-memory 512m \
    --packages org.apache.hadoop:hadoop-aws:3.3.4,com.amazonaws:aws-java-sdk-bundle:1.12.261,org.postgresql:postgresql:42.7.4 \
    "$(dirname "$0")/batch_analytics.py" \
    "$S3_URI" \
    "$WORKER_COUNT"

# ============================================================
# Step 5 — Done (cleanup trap akan terminate workers otomatis)
# ============================================================
echo ""
echo "============================================"
echo "Job selesai. Workers akan di-terminate oleh cleanup trap."
echo "============================================"