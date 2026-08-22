FROM python:3.12-slim-bookworm

# Security run as non-root 
RUN groupadd -r sparkuser && useradd -r -g sparkuser -m -d /home/sparkuser sparkuser

# Install openJDK 17 for PySpark
RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-17-jre-headless \
    && rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"

WORKDIR /spark-jobs

# Cache dependency layer
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Pre-download Spark dependency JARs during build (cached in Docker layer)
# This avoid downloading ~30MB from Maven Central on every container run
RUN python3.12 -c "\
from pyspark.sql import SparkSession; \
SparkSession.builder \
    .config('spark.jars.packages', \
            'org.apache.hadoop:hadoop-aws:3.3.4,' \
            'com.amazonaws:aws-java-sdk-bundle:1.12.261,' \
            'org.postgresql:postgresql:42.7.4') \
    .getOrCreate() \
    .stop()"

# Copy job scripts
COPY batch_analytics.py export_to_parquet.py ./

# Create data directory and assign ownership to sparkuser
RUN mkdir -p /spark-jobs/data/parquet && chown -R sparkuser:sparkuser /spark-jobs

USER sparkuser

# No ENTRYPOINT - Command spesified at docker run time per job