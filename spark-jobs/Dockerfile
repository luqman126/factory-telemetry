FROM python:3.12-slim-bookworm

# Security run as non-root 
RUN groupadd -g 1000 sparkuser && useradd -u 1000 -g sparkuser -m -d /home/sparkuser sparkuser

# Install openJDK 17 for PySpark
RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-17-jre-headless \
    curl \
    && rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"

WORKDIR /spark-jobs

# Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Download pinned Spark JARs directly into PySpark's classpath (Deterministic)
RUN PYSPARK_JARS="$(python3.12 -c 'import pyspark, os; print(os.path.join(pyspark.__path__[0], "jars"))')" && \
    curl -fsSL https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/3.3.4/hadoop-aws-3.3.4.jar \
      -o "${PYSPARK_JARS}/hadoop-aws-3.3.4.jar" && \
    curl -fsSL https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/1.12.261/aws-java-sdk-bundle-1.12.261.jar \
      -o "${PYSPARK_JARS}/aws-java-sdk-bundle-1.12.261.jar" && \
    curl -fsSL https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.4/postgresql-42.7.4.jar \
      -o "${PYSPARK_JARS}/postgresql-42.7.4.jar"

# Copy job scripts
COPY batch_analytics.py export_to_parquet.py ./

# Create data directory and assign ownership to sparkuser
RUN mkdir -p /spark-jobs/data/parquet && chown -R sparkuser:sparkuser /spark-jobs

USER sparkuser

# No ENTRYPOINT - Command spesified at docker run time per job