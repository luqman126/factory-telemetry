FROM python:3.12-slim-bookworm

# Security run as non-root 
RUN groupadd -r simulator && useradd -r -g simulator -m -d /home/simulator simulator

WORKDIR /simulator

# Cache dependency layer
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy job scripts
COPY simulator.py ./

USER simulator

# No entrypoint command so that we can control the running of simulator directly inside the container
# CMD ["python3.12", "simulator.py"]