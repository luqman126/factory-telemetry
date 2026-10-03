# Staging Infrastructure Retrospective: Resolved Challenges

This document captures the key engineering failures, debugging processes, and automated fixes encountered during the deployment of the Cloud Staging Environment. It serves as a historical record of resolved challenges and operational design improvements.

---

## 1. Network & Provisioning Challenges

### Issue: SSM Run Command Execution Timeout
- **Symptom:** Remote scripts triggered via AWS Systems Manager (SSM) timed out or failed to connect immediately after instance creation.
- **Cause:** Fresh EC2 instances require 30 to 60 seconds after boot to launch the SSM agent and register as `Online` in the Systems Manager dashboard. Running commands before registration completes results in connection timeouts.
- **Solution:** Added a polling loop in the local bootstrap orchestrator (`local-bootstrap.sh`) that checks instance status via the AWS CLI `describe-instance-information` API and waits for `PingStatus == Online` before executing payload scripts.

### Issue: S3 Gateway Endpoint Route Configuration
- **Symptom:** Database instances in the private subnet timed out when performing API operations or downloading packages from Amazon S3.
- **Cause:** Private subnets are isolated and do not route traffic to the public internet. Accessing standard S3 endpoints requires routing traffic through a NAT Gateway or a VPC Gateway Endpoint.
- **Solution:** Provisioned a free VPC Gateway Endpoint for S3 and associated it with the private subnet's route table. Private subnet database and worker nodes now route S3 requests over AWS internal fiber.

### Issue: Tailscale Re-creation DNS Cache Mismatch
- **Symptom:** The local IoT simulator threw connection timeout errors when trying to connect to the MQTT broker at `<staging-mqtt-domain>`.
- **Cause:** Rebuilding the `applayer-1` instance generated a new Tailscale interface IP (`<tailscale-new-ip>`), while the Cloudflare DNS record for `<staging-mqtt-domain>` was still pointing to the cached IP of the destroyed instance (`<tailscale-old-ip>`).
- **Solution:** Updated the Cloudflare DNS record to map to the new Tailscale IP, restoring internal VPN routing.

### Issue: EC2 User-Data Execution Gap on SSM Parameter Update
- **Symptom:** After updating an expired `tailscale_auth_key` in `staging.secrets.tfvars` and executing `deploy-environment.sh`, the `applayer-1` node failed to connect to the Tailscale network, causing the Ansible inventory discovery to fail.
- **Cause:** EC2 `user_data` scripts only run on initial instance launch. Updating an AWS SSM Parameter Store value via Terraform updates the parameter in AWS in-place, but does not alter the EC2 instance resource definition. Terraform therefore did not trigger instance replacement, and the running instance never re-executed its boot registration script with the new key.
- **Solution:** Marked the instance for replacement using `terraform taint aws_instance.applayer` and re-ran `deploy-environment.sh`. This forced Terraform to recreate the instance, properly executing `user_data` on boot with the updated auth key.

### Issue: Ephemeral Worker Launch Failure (ec2:CreateTags Policy Gap)
- **Symptom:** Launching the Spark ephemeral worker via `run_with_worker.sh` crashed with an `UnauthorizedOperation` error stating `is not authorized to perform: ec2:CreateTags on resource: arn:aws:ec2:ap-southeast-1:...:instance/*`.
- **Cause:** The script launches worker instances with `--tag-specifications` to set the worker's Name tag during creation. In AWS, assigning tags during instance creation requires the `ec2:CreateTags` permission. Our strict IAM role policy `least_privilege` was missing this action.
- **Solution:** Added `"ec2:CreateTags"` to the `least_privilege` policy list in `infra/terraform/compute.tf` and ran `terraform apply`.

### Issue: Expiring Tailscale CI/CD Auth Keys
- **Symptom:** The GitHub Actions pipeline used temporary/expiring Tailscale Auth Keys, leading to potential silent CI/CD breakage.
- **Cause:** Tailscale Auth Keys expire periodically unless explicitly created as non-expiring. They also inherit broad permissions from the user who generated them.
- **Solution:** Migrated the connection step in `.github/workflows/deploy-staging.yml` to use secure, non-expiring OAuth Client credentials (`TAILSCALE_CLIENT_ID` and `TAILSCALE_CLIENT_SECRET`) scoped strictly to ACL tag `tag:ci`.

### Issue: Host Resource Exhaustion via Default Spark Daemon Memory Allocations
- **Symptom:** Rerunning the analytics job in distributed standalone mode hung indefinitely at the `Repartitioned to 4 partitions` step.
- **Cause:** By default, the Spark Master and Spark Worker daemon JVM processes each allocate 1GB (1024MB) of memory at startup. When running on `t3.small` nodes (2GB total RAM), starting these daemons alongside the OS, backend services, and driver/executor JVMs exceeded the physical memory limits, causing severe host-level page swapping and process freezes.
- **Solution:** Injected `SPARK_DAEMON_MEMORY=256m` prefix variables to both the master startup and worker startup commands inside `run_with_worker.sh` to limit daemon memory consumption to 256MB. This keeps overall memory consumption well below the 2GB limit, stabilizing host operation.

### Issue: Spark Shuffle Block Transfer Port Block (Intermittent Hang at Repartitioning)
- **Symptom:** PySpark analytics jobs running in distributed standalone mode with workers hung for 9 to 14 minutes at the `Repartitioned to 4 partitions` step, generating `RetryingBlockTransferor: Exception while beginning fetch of 1 outstanding blocks` in the executor logs.
- **Cause:** While the worker security group allowed outbound TCP traffic and SSH (port 22) ingress, it blocked inbound traffic on all other ports. During a shuffle (like `repartition`), the Driver must connect to the executor's BlockManager on the worker node, and executors on different workers must connect to each other to transfer data blocks.
- **Solution:** Updated `security.tf` to add ingress rules allowing all TCP ports (`0-65535`) from the `applayer` security group and from the `worker` security group itself (self-ingress), allowing unimpeded cluster orchestration and shuffle exchanges.

### Issue: Spark Executor RAM Disk Spill & OOM (No space left on device)
- **Symptom:** Rerunning the analytics job with a massive dataset (5,000,000 records) failed with `Unable to create executor due to No space left on device` and `Not enough space to cache rdd_... in memory!`.
- **Cause:** Two interlocked issues caused this. First, the data was repartitioned into too few partitions (e.g., 4 partitions for 5M records), causing each massive chunk to instantly exceed the small 768MB executor heap, leading to a Garbage Collection freeze (OOM) and executor death loops. Second, when Spark attempted to spill the excess memory to disk or download external jars (like the 280MB AWS SDK), it wrote to the OS default `/tmp` directory. On Amazon Linux, `/tmp` is a `tmpfs` (RAM Disk) restricted to half of system memory (1GB), which instantly filled up.
- **Solution:** Modified `batch_analytics.py` to dynamically scale the partition count (`max(worker_count * 10, 20)`) to ensure bite-sized chunks that fit in the JVM heap. Additionally, injected `SPARK_LOCAL_DIRS=/opt/spark/work` into the worker daemon startup sequence in `run_with_worker.sh`, forcing the Standalone cluster manager to route all executor disk spills and Ivy package downloads to the 30GB physical EBS volume instead of the RAM Disk.

### Issue: S3 /dev/null Special Device Copying Failure
- **Symptom:** The database nodes remained stuck in the `Waiting for package sync to complete in S3...` polling loop.
- **Cause:** The sync script used `aws s3 cp /dev/null s3://.../sync_complete.flag` to signal completion. However, AWS CLI skips `/dev/null` because it is a character special device, preventing the flag file from being uploaded.
- **Solution:** Migrated to `aws s3api put-object` which directly initiates an API request to write a zero-byte object in S3 without interacting with local special file descriptors.

---

## 2. Ingestion & Storage Provisioning Issues

### Issue: Database Provisioning Packages Timeout
- **Symptom:** Database nodes in the private subnet timed out trying to connect to standard PostgreSQL and TimescaleDB package repositories.
- **Cause:** The private subnets do not route traffic to the public internet. Thus, standard repository access is blocked.
- **Solution:** Configured the Bastion to run `dnf download --resolve --alldeps` to download all database packages locally and upload them to S3. The database nodes then fetch the RPM packages from S3 via the VPC S3 Endpoint.

### Issue: Empty local-exec Provisioner Success Exit Codes
- **Symptom:** `terraform apply` reported success even when the remote SSM bootstrap script crashed on the Bastion.
- **Cause:** The `local-bootstrap.sh` script monitored the command status but did not contain an explicit `exit 1` inside its failure conditions, allowing execution to slide to exit code `0`.
- **Solution:** Modified the SSM return checker block in `local-bootstrap.sh` to trigger an explicit `exit 1` if the returned command status is not `"Success"`.

### Issue: TimescaleDB Library Paths Mismatch on AL2023
- **Symptom:** The PostgreSQL service failed to start, throwing errors stating `could not access file "timescaledb"`.
- **Cause:** TimescaleDB RPMs assume PostgreSQL installation paths used by PGDG repos (`/usr/pgsql-16/`), while Amazon Linux 2023 installs PostgreSQL under standard system library paths (`/usr/lib64/pgsql/`).
- **Solution:** Configured automated symbolic links to map TimescaleDB `.so` library files and extension `.control` files into AL2023 system paths during database setup.

### Issue: Overly Loose Mosquitto Broker ACLs
- **Symptom:** Every connecting IoT device was granted global wildcard permissions (`topic readwrite #`), allowing any client to intercept or forge other devices' telemetry and actuator commands.
- **Cause:** The default `mosquitto/acl` configuration mapped all users to the global `#` wildcard.
- **Solution:** Hardened the ACL file (`infra/mosquitto/acl`) to grant read/write access to the database consumer user (`kagebyo`) on `iot/#`, while dynamically restricting individual devices to their own client paths using Mosquitto's `%u` (username) wildcard:
  - `pattern write iot/sensor/%u/+`
  - `pattern read iot/commands/%u/+`

### Issue: Unstructured Data Returned by /latest Endpoint
- **Symptom:** The `/sensors/latest/{device_id}` HTTP endpoint returned a list of raw database tuples without column headers, making the API brittle and unusable for external consumers.
- **Cause:** The query executed on the database connection pool used the default cursor which returns raw rows as python lists/tuples.
- **Solution:** Refactored the endpoint in `backend/app/routes/sensor.py` to import `RealDictCursor` from `psycopg2.extras` and passed it as the `cursor_factory` parameter. The endpoint now returns clean, structured key-value maps.

---

## 3. Spark & Java Environment Issues

### Issue: PySpark Installation Disk Exhaustion
- **Symptom:** Spark worker nodes threw `No space left on device` errors when registering executors or running heavy aggregation shuffles.
- **Cause:** PySpark, Hadoop AWS dependencies, and temporary shuffle partition spills consumed significant disk space, exhausting default 8GB EBS volumes.
- **Solution:** Increased default root EBS volume size to 30GB gp3 for the custom worker AMI configuration.

### Issue: Java Path Dependency Under Systemd
- **Symptom:** Spark analytics jobs failed to submit via automated timers, logging `JAVA_HOME is not set` errors.
- **Cause:** Systemd service environments run under isolated login shells that do not inherit standard user environment profiles (`/etc/profile.d/`).
- **Solution:** Added explicit environment statements directly inside the systemd service file definitions:
  ```ini
  Environment="JAVA_HOME=/usr/lib/jvm/java-21-amazon-corretto"
  Environment="SPARK_HOME=/opt/spark"
  ```

### Issue: Hardcoded Ephemeral Worker SSH Key
- **Symptom:** Step 3 of the benchmark script (`run_with_worker.sh`) threw `Warning: Identity file /home/ec2-user/.ssh/iot-worker-key not accessible` and failed to connect.
- **Cause:** The script contained a hardcoded mock public key in its `USER_DATA` block. When launched, the EC2 instance rejected the connection because the caller's key did not match the static mock key.
- **Solution:** Modified `run_with_worker.sh` to implement a self-healing check. The script now dynamically verifies if `~/.ssh/iot-worker-key` exists. If missing, it automatically runs `ssh-keygen` to generate a fresh pair on-the-fly and loads the public key dynamically into `USER_DATA`.

### Issue: Standalone Spark Master Service Inactive
- **Symptom:** Rerunning the ephemeral worker script failed with `Failed to connect to master 10.1.1.54:7077` and standalone workers failed to register.
- **Cause:** The standalone Spark Master daemon was not started on `applayer-1` after staging environment reboots, preventing coordinator connections.
- **Solution:** Added automated, self-healing initialization checking to `run_with_worker.sh`. The script now checks for the Master JVM process on launch, starts it dynamically if inactive, and automatically shuts it down during the `cleanup()` exit trap to free up compute resources when the job completes.

---

## 4. Configuration Management & Infrastructure State Challenges

### Issue: SSH ProxyCommand Tunneling for Air-Gapped Private Subnet Nodes
- **Symptom:** Running `ansible-playbook` against private database nodes (`datalayer-1`/`datalayer-2`) failed with `Connection closed by UNKNOWN port 65535`.
- **Cause:** Standard `ProxyJump` did not pass the private key (`iot-bigdata-key.pem`) through for the second SSH hop inside Ansible's connection engine.
- **Solution:** Configured OpenSSH `ProxyCommand` in `ansible/inventory/hosts.ini` with explicit key parameters: `-o ProxyCommand="ssh -i ~/.ssh/iot-bigdata-key.pem -W %h:%p -q ec2-user@100.105.19.59"`. Private nodes now accept Ansible tasks seamlessly over the Tailscale bastion tunnel without exposing raw web ports.

### Issue: DNF Package Manager Backend Error on Control Node (Ubuntu vs AL2023)
- **Symptom:** Running tasks with `ansible.builtin.dnf` against `localhost` failed with `Could not detect which major revision of dnf is in use`.
- **Cause:** The local control node runs Ubuntu (`apt`), while target nodes run Amazon Linux 2023 (`dnf`). Running RPM tasks locally triggered package manager mismatch errors.
- **Solution:** Kept `ansible.builtin.dnf` explicitly targeted at RPM nodes (`db_primary`, `db_replica`, `app_nodes`), and tested local playbook syntax separately from target host executions.

### Issue: Terraform S3 Remote Backend Migration & Deprecated DynamoDB Locking
- **Symptom:** Local `.tfstate` risked single-point-of-failure data loss and blocked collaboration. Using `dynamodb_table` for state locking triggered `Warning: dynamodb_table is deprecated. Use use_lockfile instead` in Terraform 1.10+.
- **Cause:** Terraform 1.10+ introduced native S3 object lock files (`use_lockfile = true`) as a built-in replacement for external DynamoDB locking tables.
- **Solution:** Created standalone `infra/terraform-bootstrap/` module to provision `iot-bigdata-terraform-state` S3 bucket with versioning and `prevent_destroy`. Migrated main infrastructure state via `terraform init -migrate-state` and configured native `use_lockfile = true` in `infra/terraform/main.tf`, eliminating DynamoDB table overhead and deprecation warnings completely.

### Issue: TimescaleDB Symlink Idempotency & Shell Module Vulnerabilities
- **Symptom:** Re-running the `timescaledb_primary` Ansible playbook on the database replica caused catastrophic failures, corrupting database node roles and disconnecting the replica.
- **Cause:** The Ansible playbook originally used the raw `shell` module to perform naive `find` and `ln -sf` operations for TimescaleDB library symlinking. Running these commands repeatedly altered permissions indiscriminately, breaking Patroni replication and idempotency principles.
- **Solution:** Refactored the Ansible roles `timescaledb_primary` and `timescaledb_replica` to replace raw shell commands with native `ansible.builtin.find` and `ansible.builtin.file` modules. This ensures declarative, idempotent execution where symlinks are only created if missing, and state remains unchanged on subsequent runs, restoring replica connectivity and stability.

### Issue: Inconsistent Database Schema State & Migration Management
- **Symptom:** Changes to the wide-column analytics schema were not systematically tracked or applied, risking schema drift between environments and missing `schema_migrations` history.
- **Cause:** Schema updates were initially applied ad-hoc via `init.sql` instead of a standardized migration tool, making it difficult to understand the database schema history.
- **Solution:** Adopted `dbmate` inside a one-shot CI/CD Docker container via `run_migrations.sh`. Migrations are now strictly tracked using the 14-digit timestamp naming convention (e.g., `20260829000000_wide_column_analytics.sql`), ensuring a complete, reproducible history in the database's `schema_migrations` table without requiring a persistent daemon on the cluster.
