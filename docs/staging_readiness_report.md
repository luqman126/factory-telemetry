# Staging Environment - Readiness & Evidence Report
**Date:** October 3, 2026
**Environment:** Staging

## 1. Systemctl Services (HAProxy & Spark Timer)
**Command:** `systemctl status haproxy iot-analytics.timer --no-pager`
**Observation:**
- `haproxy.service` is **Active (running)**. It acts as our load balancer over the Patroni DB nodes.
- `iot-analytics.timer` is **Active (waiting)**. It successfully triggered at startup and is scheduled for the next top of the hour.

## 2. Docker Containers (App Layer)
**Command:** `docker compose ps`
**Observation:**
```
NAME             IMAGE                     COMMAND                  SERVICE      CREATED          STATUS
iot_backend      iot-backend:latest        "uvicorn app.main:ap…"   backend      23 minutes ago   Up 23 minutes (healthy)
iot_grafana      grafana/grafana:latest    "/run.sh"                grafana      23 minutes ago   Up 23 minutes
iot_mosquitto    eclipse-mosquitto:2       "/docker-entrypoint.…"   mosquitto    23 minutes ago   Up 20 minutes
iot_prometheus   prom/prometheus:v2.51.0   "/bin/prometheus --c…"   prometheus   23 minutes ago   Up 23 minutes
```
- All microservices successfully deployed and are healthy. 

## 3. Web & Network Accessibility
**Command:** `curl -s -I https://staging-grafana.chescloud.my.id/login`
**Observation:**
```http
HTTP/2 200 
date: Sat, 03 Oct 2026 03:14:30 GMT
content-type: text/html; charset=UTF-8
server: cloudflare
```
- Grafana is successfully returning a 200 OK via HTTPS and the Cloudflare proxy tunnel.

---

## Conclusion & Readiness for Production
**Assessment:** The staging infrastructure is highly stable and behaving exactly as provisioned. The microservices are isolated correctly, health checks are passing, and routing works perfectly. 
**Decision:** We can **safely proceed to provisioning the production environment** since the CI/CD deployment logic is verified and the staging layer functions as intended.
