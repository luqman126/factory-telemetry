# === Migration Stage ===
FROM python:3.12-slim AS migrations

RUN python3 -c 'import urllib.request; urllib.request.urlretrieve("https://github.com/amacneil/dbmate/releases/download/v2.17.0/dbmate-linux-amd64", "/usr/local/bin/dbmate")' \
    && chmod +x /usr/local/bin/dbmate

# === Runtime Stage ===
FROM python:3.12-slim AS runtime

# Security run as non-root
RUN groupadd -r appuser && useradd -r -g appuser appuser

WORKDIR /backend

# Cache dependency layer separately from app code
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY ./app ./app

USER appuser

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
